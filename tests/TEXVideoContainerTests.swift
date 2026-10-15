import Cocoa
import AVFoundation
func check(_ condition: Bool, _ message: String) { precondition(condition, message); print("PASS", message) }
func box(_ type: String, _ payload: Data, extended: Bool = false) -> Data {
    var d = Data()
    func be(_ n: UInt64, _ count: Int) { for shift in (0..<count).reversed() { d.append(UInt8(truncatingIfNeeded: n >> (shift * 8))) } }
    be(extended ? 1 : UInt64(payload.count + 8), 4); d.append(Data(type.utf8))
    if extended { be(UInt64(payload.count + 16), 8) }
    d.append(payload); return d
}
func mp4(_ brand: String = "mp42", compatible: String = "isom", extended: Bool = false) -> Data {
    box("ftyp", Data(brand.utf8) + Data(repeating: 0, count: 4) + Data(compatible.utf8), extended: extended)
}
func fixture(_ version: Int, _ payload: Data, compressed: Bool = false, metadata: Bool = false,
             flags: UInt32 = 32, width: UInt32 = 16, height: UInt32 = 16, encoded: UInt32 = .max,
             invalidJSON: Bool = false, unpackedOverride: UInt32? = nil) -> Data {
    var d = Data("TEXV0005\0TEXI0001\0".utf8)
    func u(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
    for n in [0, flags, width, height, width, height, 0] { u(n) }
    d.append(Data(String(format: "TEXB%04d\0", version).utf8)); u(1)
    if version >= 3 { u(encoded) }
    if version == 4 { u(metadata ? 1 : 0) }
    u(1)
    if metadata { u(1); u(2); d.append(Data((invalidJSON ? "oops\0" : "{}\0").utf8)); u(1) }
    u(width); u(height)
    var stored = payload
    if compressed {
        stored = Data([UInt8(min(payload.count, 15) << 4)])
        if payload.count >= 15 {
            var remaining = payload.count - 15
            while remaining >= 255 { stored.append(255); remaining -= 255 }
            stored.append(UInt8(remaining))
        }
        stored.append(payload)
    }
    if version >= 2 { u(compressed ? 1 : 0); u(unpackedOverride ?? (compressed ? UInt32(payload.count) : 0)) }
    u(UInt32(stored.count)); d.append(stored); return d
}
let movie = mp4()
for version in 1...4 {
    for compressed in (version == 1 ? [false] : [false, true]) {
        for metadata in (version == 4 ? [false, true] : [false]) {
            let data = fixture(version, movie, compressed: compressed, metadata: metadata)
            check(TEXParser(data: data).extractVideoData() == movie, "v\(version) compressed=\(compressed) metadata=\(metadata)")
            for length in 0..<data.count {
                precondition(TEXParser(data: Data(data.prefix(length))).extractVideoData() == nil, "Truncation at \(length)")
            }
            check(TEXParser(data: data).extractImage() == nil, "video excluded from image decoding")
        }
    }
    let pixels = Data(repeating: 255, count: 8)
    let image = TEXParser(data: fixture(version, pixels, flags: 0, width: 1, height: 2)).extractImage()
    check(image?.size == CGSize(width: 1, height: 2), "v\(version) 1x2 raw image (not V4 metadata)")
}
for brand in ["msnv", "iso6", "avc1", "M4V "] {
    let bytes = mp4(brand)
    check(TEXParser(data: fixture(3, bytes)).extractVideoData() == bytes, "brand \(brand)")
}
for bytes in [mp4("zzzz"), mp4(extended: true), box("free", Data(repeating: 0, count: 4)) + movie] {
    check(TEXParser(data: fixture(2, bytes, flags: 0)).extractVideoData() == bytes, "compatible brand / extended box / leading free")
}
check(TEXParser(data: fixture(3, mp4("zzzz", compatible: "xxxx"), flags: 32)).extractVideoData() != nil, "declared video permits other BMFF brands")
check(TEXParser(data: fixture(3, mp4("zzzz", compatible: "xxxx"), flags: 0)).extractVideoData() == nil, "unknown unmarked BMFF rejected")
for bytes in [Data(repeating: 0, count: 32), mp4("avif"), box("ftyp", Data("mp42".utf8)), Data("junk".utf8) + movie] {
    check(TEXParser(data: fixture(3, bytes)).extractVideoData() == nil, "invalid/non-video payload rejected")
}
check(TEXParser(data: fixture(4, movie, metadata: true, invalidJSON: true)).extractVideoData() == nil, "invalid V4 JSON rejected")
check(TEXParser(data: fixture(3, movie, compressed: true, unpackedOverride: 999)).extractVideoData() == nil, "LZ4 length mismatch rejected")
check(TEXParser(data: fixture(3, movie, compressed: true, unpackedOverride: .max)).extractVideoData() == nil, "oversized allocation rejected")
check(TEXParser(data: fixture(5, movie)).extractVideoData() == nil, "unknown container rejected")
check(TEXParser(data: fixture(3, movie, width: .max)).extractVideoData() == nil, "oversized dimensions rejected")
// Animated atlases use the same mip parser, including older versions and LZ4.
for version in 1...4 {
    var bytes = fixture(version, Data([255, 0, 0, 255]), compressed: version >= 2, flags: 5, width: 1, height: 1)
    bytes.append(Data("TEXS0002\0".utf8))
    func u(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) } }
    u(1); u(0); u(Float(0.1).bitPattern)
    for n: Float in [0, 0, 1, 1, 1, 1] { u(n.bitPattern) }
    let animation = TEXParser(data: bytes).extractAnimation()
    check(animation?.frames.count == 1 && animation?.nearestFiltering == true, "v\(version) animated atlas")
}
// Optional real library audit: every video-flagged TEX must extract and decode.
if CommandLine.arguments.count > 1 {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)!
    var textures = 0, videos = 0
    for case let url as URL in enumerator where url.pathExtension == "pkg" {
        let pkg = try PKGParser(url: url)
        for name in pkg.fileList where name.hasSuffix(".tex") {
            let data = pkg.extractFile(named: name)!
            textures += 1
            guard data.count > 26, data[22] & 32 != 0 else { continue }
            let parser = TEXParser(data: data)
            guard let video = parser.extractVideoData() else { fatalError("Cannot extract \(url.path):\(name)") }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            try video.write(to: temp); defer { try? FileManager.default.removeItem(at: temp) }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: temp))
            let frame = try generator.copyCGImage(at: .zero, actualTime: nil)
            check(frame.width > 0 && frame.height > 0, "real \(url.deletingLastPathComponent().lastPathComponent)/\(name): \(frame.width)x\(frame.height)")
            videos += 1
        }
    }
    check(videos > 0, "library audit: \(textures) TEX, \(videos) decoded videos")
}
