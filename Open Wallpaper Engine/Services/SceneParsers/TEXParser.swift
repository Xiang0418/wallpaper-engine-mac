import Cocoa
import Foundation

/// TEXV0005 containers. TEXI dimensions are allocated size followed by content size.
struct TEXAnimation {
    struct Frame { let imageIndex: Int; let rect: CGRect; let size: CGSize; let duration: Double }
    let images: [NSImage]
    let nearestFiltering: Bool
    let frames: [Frame]
}

final class TEXParser {
    private let data: Data
    init(data: Data) { self.data = Data(data) }

    /// All consumers share the same versioned header, mip layout and LZ4 decoder.
    private struct Reader {
        let data: Data
        var offset = 0
        mutating func u32() -> UInt32? {
            guard offset <= data.count - 4 else { return nil }
            defer { offset += 4 }
            return (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
        }
        mutating func magic() -> String? {
            guard offset <= data.count - 9, data[offset + 8] == 0 else { return nil }
            defer { offset += 9 }
            return String(data: data[offset..<offset + 8], encoding: .ascii)
        }
        mutating func metadata() -> Bool {
            // V4 editor metadata: 1, 2, NUL-terminated JSON, 1.
            guard u32() == 1, u32() == 2 else { return false }
            let end = min(data.count, offset + 64 * 1024)
            guard let zero = data[offset..<end].firstIndex(of: 0),
                  let json = try? JSONSerialization.jsonObject(with: data[offset..<zero]),
                  json is [String: Any] || json is [Any] else { return false }
            offset = zero + 1
            return u32() == 1
        }
    }
    private struct Header {
        let format: Int, flags: UInt32, width: Int, height: Int
        let version: Int, count: Int, encoded: UInt32, video: Bool
    }
    private struct Mip {
        let format: Int, width: Int, height: Int, contentWidth: Int, contentHeight: Int
        let encodedFormat: UInt32
        let bytes: [UInt8]
    }
    private func header(_ reader: inout Reader) -> Header? {
        guard reader.magic() == "TEXV0005", reader.magic() == "TEXI0001",
              let format = reader.u32(), let flags = reader.u32(),
              reader.u32() != nil, reader.u32() != nil,
              let width = reader.u32(), let height = reader.u32(), reader.u32() != nil,
              let magic = reader.magic(),
              let version = ["TEXB0001", "TEXB0002", "TEXB0003", "TEXB0004"].firstIndex(of: magic),
              let count = reader.u32(), count > 0, count <= 256 else { return nil }
        var encoded: UInt32 = .max, video: UInt32 = 0
        if version >= 2 { guard let value = reader.u32() else { return nil }; encoded = value }
        if version == 3 { guard let value = reader.u32(), value <= 1 else { return nil }; video = value }
        return Header(format: Int(format), flags: flags, width: Int(width), height: Int(height),
                      version: version + 1, count: Int(count), encoded: encoded,
                      video: flags & 32 != 0 || video == 1)
    }
    private func mip(_ reader: inout Reader, header: Header, decode: Bool = true, atlas: Bool = false) -> Mip? {
        if header.version == 4 {
            var probe = reader
            // Real V4 files also use plain V3 mip layouts. Only the explicit
            // metadata prefix selects the extended layout; never scan for payloads.
            if probe.u32() == 1, probe.u32() == 2, let next = probe.u32(), next > 1 {
                guard reader.metadata() else { return nil }
            }
        }
        guard let w = reader.u32(), let h = reader.u32(),
              w > 0, h > 0, w <= 16384, h <= 16384,
              UInt64(w) * UInt64(h) <= 64 * 1024 * 1024 else { return nil }
        var compression: UInt32 = 0, unpacked: UInt32 = 0
        if header.version >= 2 {
            guard let c = reader.u32(), c <= 1, let n = reader.u32(), n <= 256 * 1024 * 1024 else { return nil }
            compression = c; unpacked = n
        }
        guard let length = reader.u32(), length <= 256 * 1024 * 1024,
              Int(length) <= data.count - reader.offset else { return nil }
        let start = reader.offset
        reader.offset += Int(length)
        var bytes = decode ? Array(data[start..<reader.offset]) : []
        if decode && compression == 1 {
            guard let result = Self.decodeLZ4(bytes, size: Int(unpacked)) else { return nil }
            bytes = result
        }
        return Mip(format: header.format, width: Int(w), height: Int(h),
                   contentWidth: atlas ? Int(w) : min(header.width, Int(w)),
                   contentHeight: atlas ? Int(h) : min(header.height, Int(h)),
                   encodedFormat: header.encoded, bytes: bytes)
    }
    private func firstMip() -> (Header, Mip)? {
        var reader = Reader(data: data)
        guard let h = header(&reader), let count = reader.u32(), count > 0, count <= 32,
              let m = mip(&reader, header: h) else { return nil }
        return (h, m)
    }

    /// Validate an ISO BMFF file-type box at a box boundary, including compatible
    /// brands. Codec support is decided later by AVFoundation, not the TEX reader.
    private static func isMP4(_ bytes: [UInt8], declaredVideo: Bool) -> Bool {
        let brands: Set<String> = ["isom", "iso2", "iso3", "iso4", "iso5", "iso6", "iso7", "iso8", "iso9",
                                   "mp41", "mp42", "avc1", "M4V ", "M4VH", "M4VP", "msnv", "dash"]
        var offset = 0
        for _ in 0..<32 {
            guard offset <= bytes.count - 8 else { return false }
            func be(_ start: Int, _ count: Int) -> UInt64 {
                bytes[start..<start + count].reduce(0) { ($0 << 8) | UInt64($1) }
            }
            var size = be(offset, 4), headerSize = 8
            let type = String(bytes: bytes[offset + 4..<offset + 8], encoding: .ascii)
            if size == 1 {
                guard offset <= bytes.count - 16 else { return false }
                size = be(offset + 8, 8); headerSize = 16
            }
            guard size >= UInt64(headerSize), size <= UInt64(bytes.count - offset) else { return false }
            if type == "ftyp" {
                let payload = offset + headerSize, end = offset + Int(size)
                guard end - payload >= 8, (end - payload - 8) % 4 == 0 else { return false }
                let major = String(bytes: bytes[payload..<payload + 4], encoding: .ascii) ?? ""
                // Image-only BMFF files are not video textures.
                if ["avif", "avis", "heic", "heix", "mif1", "msf1"].contains(major) { return false }
                if declaredVideo || brands.contains(major) { return true }
                return stride(from: payload + 8, to: end, by: 4).contains {
                    brands.contains(String(bytes: bytes[$0..<$0 + 4], encoding: .ascii) ?? "")
                }
            }
            guard type == "free" || type == "skip" || type == "wide" else { return false }
            offset += Int(size)
        }
        return false
    }
    func extractVideoData() -> Data? {
        guard let (header, mip) = firstMip(), Self.isMP4(mip.bytes, declaredVideo: header.video) else { return nil }
        return Data(mip.bytes)
    }

    /// Raw LZ4 blocks (not Apple's framed COMPRESSION_LZ4 stream).
    static func decodeLZ4(_ input: [UInt8], size: Int) -> [UInt8]? {
        guard size > 0, size <= 256 * 1024 * 1024 else { return nil }
        var out = [UInt8](); out.reserveCapacity(size)
        var i = 0
        func length(_ initial: Int) -> Int? {
            var n = initial
            if n == 15 {
                while true {
                    guard i < input.count else { return nil }
                    let byte = Int(input[i]); i += 1; n += byte
                    guard n <= size else { return nil }
                    if byte != 255 { break }
                }
            }
            return n
        }
        while i < input.count {
            let token = input[i]; i += 1
            guard let literals = length(Int(token >> 4)), literals <= input.count - i,
                  literals <= size - out.count else { return nil }
            out.append(contentsOf: input[i..<i+literals]); i += literals
            if i == input.count { break }
            guard i + 2 <= input.count else { return nil }
            let offset = Int(input[i]) | Int(input[i+1]) << 8; i += 2
            guard offset > 0, offset <= out.count, let match = length(Int(token & 15)),
                  match + 4 <= size - out.count else { return nil }
            for _ in 0..<match+4 { out.append(out[out.count-offset]) }
        }
        return out.count == size ? out : nil
    }

    func extractImage() -> NSImage? {
        guard let (header, mip) = firstMip(), !header.video,
              !Self.isMP4(mip.bytes, declaredVideo: false) else { return nil }
        return image(from: mip)
    }

    private func image(from mip: Mip) -> NSImage? {
        if mip.encodedFormat != .max {
            // Decode only the declared payload; never scan pixel bytes for JPEG markers.
            return NSImage(data: Data(mip.bytes))
        }
        let count = mip.width * mip.height
        var pixels = [UInt8](repeating: 255, count: count * 4)
        switch mip.format {
        case 0:
            guard mip.bytes.count == count * 4 else { return nil }
            pixels = mip.bytes
        case 8, 9:
            let channels = mip.format == 9 ? 1 : 2
            guard mip.bytes.count == count * channels else { return nil }
            for i in 0..<count {
                let value = mip.bytes[i * channels]
                pixels[i*4] = value; pixels[i*4+1] = value; pixels[i*4+2] = value
                pixels[i*4+3] = channels == 2 ? mip.bytes[i*2+1] : 255
            }
        case 4, 6, 7:
            guard let decoded = Self.decodeBC(mip.bytes, width: mip.width, height: mip.height, format: mip.format) else { return nil }
            pixels = decoded
        default: return nil
        }
        guard mip.contentWidth > 0, mip.contentHeight > 0,
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let full = CGImage(width: mip.width, height: mip.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: mip.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let cropped = full.cropping(to: CGRect(x: 0, y: 0, width: mip.contentWidth, height: mip.contentHeight)) else { return nil }
        return NSImage(cgImage: cropped, size: CGSize(width: mip.contentWidth, height: mip.contentHeight))
    }

    /// TEXS metadata follows every image/mipmap, not necessarily the first image.
    /// Keep full atlas pixels for animation; static textures retain their existing crop.
    func extractAnimation() -> TEXAnimation? {
        var reader = Reader(data: data)
        guard let h = header(&reader), h.flags & 4 != 0, !h.video else { return nil }
        let flags = h.flags
        var images: [NSImage] = [], sizes: [CGSize] = []
        var pixelBudget = 64 * 1024 * 1024
        var byteBudget = 256 * 1024 * 1024
        for _ in 0..<h.count {
            guard let count = reader.u32(), count > 0, count <= 32 else { return nil }
            for index in 0..<count {
                guard let source = mip(&reader, header: h, decode: index == 0, atlas: true) else { return nil }
                guard index == 0 else { continue }
                let pixels = source.width * source.height
                guard pixels <= pixelBudget, source.bytes.count <= byteBudget else { return nil }
                pixelBudget -= pixels; byteBudget -= source.bytes.count
                guard let image = image(from: source) else { return nil }
                if h.encoded != .max {
                    guard let bitmap = NSBitmapImageRep(data: Data(source.bytes)),
                          bitmap.pixelsWide == source.width, bitmap.pixelsHigh == source.height else { return nil }
                }
                images.append(image); sizes.append(CGSize(width: source.width, height: source.height))
            }
        }
        func u32() -> UInt32? { reader.u32() }
        func magic() -> String? { reader.magic() }
        guard let version = magic(), ["TEXS0001", "TEXS0002", "TEXS0003"].contains(version),
              let frameCount = u32(), frameCount > 0, frameCount <= 4096 else { return nil }
        if version == "TEXS0003" { guard u32() != nil, u32() != nil else { return nil } }
        var frames: [TEXAnimation.Frame] = []
        for _ in 0..<frameCount {
            guard let imageIndex = u32(), Int(imageIndex) < images.count, let durationBits = u32() else { return nil }
            let duration = Double(Float(bitPattern: durationBits))
            guard duration.isFinite else { return nil }
            var values: [Double] = []
            for _ in 0..<6 {
                guard let bits = u32() else { return nil }
                values.append(version == "TEXS0001" ? Double(bits) : Double(Float(bitPattern: bits)))
            }
            guard values.allSatisfy({ $0.isFinite }) else { return nil }
            let x = values[0], y = values[1], w = values[2], h = values[5], size = sizes[Int(imageIndex)]
            guard x >= 0, y >= 0, w > 0, h > 0, x+w <= size.width, y+h <= size.height else { return nil }
            let rect = CGRect(x: x/size.width, y: 1-(y+h)/size.height, width: w/size.width, height: h/size.height)
            frames.append(.init(imageIndex: Int(imageIndex), rect: rect, size: CGSize(width: w, height: h), duration: duration > 0 ? duration : 1.0/30))
        }
        return TEXAnimation(images: images, nearestFiltering: flags & 1 != 0, frames: frames)
    }

    func extractImageData() -> Data? {
        guard let image = extractImage(), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// BC1/BC2/BC3 software decoding also works on Macs without BC texture support.
    static func decodeBC(_ bytes: [UInt8], width: Int, height: Int, format: Int) -> [UInt8]? {
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              width * height <= 64 * 1024 * 1024, [4, 6, 7].contains(format) else { return nil }
        let stride = format == 7 ? 8 : 16
        let columns = (width+3)/4, rows = (height+3)/4
        guard bytes.count == columns * rows * stride else { return nil }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        func rgb(_ v: Int) -> [Int] { [((v>>11)&31)*255/31, ((v>>5)&63)*255/63, (v&31)*255/31] }
        for by in 0..<rows { for bx in 0..<columns {
            let base = (by*columns+bx)*stride, c = base + (format == 7 ? 0 : 8)
            let a = Int(bytes[c]) | Int(bytes[c+1])<<8, b = Int(bytes[c+2]) | Int(bytes[c+3])<<8
            var colors = [rgb(a), rgb(b), [0,0,0], [0,0,0]]
            for k in 0..<3 {
                colors[2][k] = a > b || format != 7 ? (2*colors[0][k]+colors[1][k])/3 : (colors[0][k]+colors[1][k])/2
                colors[3][k] = a > b || format != 7 ? (colors[0][k]+2*colors[1][k])/3 : 0
            }
            var alpha = [Int(bytes[base]), Int(bytes[base+1])]
            if format == 4 {
                if alpha[0] > alpha[1] { for n in 1...6 { alpha.append(((7-n)*alpha[0]+n*alpha[1])/7) } }
                else { for n in 1...4 { alpha.append(((5-n)*alpha[0]+n*alpha[1])/5) }; alpha += [0,255] }
            }
            var alphaBits: UInt64 = 0
            if format == 4 { for k in 0..<6 { alphaBits |= UInt64(bytes[base+2+k]) << (8*k) } }
            for y in 0..<4 { for x in 0..<4 {
                let px = bx*4+x, py = by*4+y
                guard px < width, py < height else { continue }
                let index = y*4+x, ci = Int((bytes[c+4+y] >> (x*2)) & 3), target = (py*width+px)*4
                for k in 0..<3 { out[target+k] = UInt8(colors[ci][k]) }
                var opacity = 255
                if format == 7 && a <= b && ci == 3 { opacity = 0 }
                if format == 4 { opacity = alpha[Int((alphaBits >> (index*3)) & 7)] }
                if format == 6 { opacity = Int((bytes[base+index/2] >> ((index%2)*4)) & 15) * 17 }
                out[target+3] = UInt8(opacity)
            }}
        }}
        return out
    }
}
