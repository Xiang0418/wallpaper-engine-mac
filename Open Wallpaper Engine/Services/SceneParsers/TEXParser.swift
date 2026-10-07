import Cocoa
import Foundation

/// TEXV0005 containers. TEXI dimensions are allocated size followed by content size.
final class TEXParser {
    private let data: Data
    init(data: Data) { self.data = Data(data) }

    /// Read the first uncompressed mip payload of a TEXB0004 video texture.
    /// Validate the MP4 file-type box rather than scanning compressed pixels for magic bytes.
    func extractVideoData() -> Data? {
        let marker = Data("TEXB0004\0".utf8)
        guard let section = data.range(of: marker) else { return nil }
        var cursor = section.upperBound
        func readUInt32() -> UInt32? {
            guard cursor + 4 <= data.endIndex else { return nil }
            let value = UInt32(data[cursor]) | (UInt32(data[cursor + 1]) << 8)
                | (UInt32(data[cursor + 2]) << 16) | (UInt32(data[cursor + 3]) << 24)
            cursor += 4
            return value
        }
        guard let textureCount = readUInt32(), textureCount > 0,
              readUInt32() != nil, // source image format
              readUInt32() != nil, // TEXB0004 extra field
              let mipCount = readUInt32(), mipCount > 0,
              let width = readUInt32(), width > 0,
              let height = readUInt32(), height > 0,
              let compression = readUInt32(), compression == 0,
              readUInt32() != nil, // uncompressed size (zero for encoded media)
              let payloadSize = readUInt32(), payloadSize >= 12,
              Int(payloadSize) <= data.endIndex - cursor else { return nil }
        let payload = Data(data[cursor..<cursor + Int(payloadSize)])
        guard payload[4..<8] == Data("ftyp".utf8) else { return nil }
        let boxSize = payload.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard boxSize >= 12, boxSize <= payloadSize else { return nil }
        let brand = String(data: payload[8..<12], encoding: .ascii)
        guard ["isom", "iso2", "mp41", "mp42", "avc1", "M4V "].contains(brand) else { return nil }
        return payload
    }

    private struct Mip {
        let format: Int, width: Int, height: Int, contentWidth: Int, contentHeight: Int
        let encodedFormat: UInt32
        let bytes: [UInt8]
    }

    private func firstMip() -> Mip? {
        guard data.starts(with: Data("TEXV0005\0TEXI0001\0".utf8)), data.count >= 46 else { return nil }
        var cursor = 18
        func u32() -> UInt32? {
            guard cursor <= data.count - 4 else { return nil }
            defer { cursor += 4 }
            return (0..<4).reduce(0) { $0 | UInt32(data[cursor + $1]) << ($1 * 8) }
        }
        guard let format = u32(), u32() != nil, u32() != nil, u32() != nil,
              let cw = u32(), let ch = u32(), u32() != nil else { return nil }
        guard cursor + 9 <= data.count,
              let section = String(data: data[cursor..<cursor+8], encoding: .ascii),
              ["TEXB0001", "TEXB0002", "TEXB0003", "TEXB0004"].contains(section),
              data[cursor+8] == 0 else { return nil }
        cursor += 9
        guard let count = u32(), count > 0 else { return nil }
        var encoded: UInt32 = .max
        if section >= "TEXB0003" { guard let value = u32() else { return nil }; encoded = value }
        if section == "TEXB0004" { guard u32() != nil else { return nil } }
        guard let mips = u32(), mips > 0, let w = u32(), let h = u32(),
              w > 0, h > 0, w <= 16384, h <= 16384,
              UInt64(w) * UInt64(h) <= 64 * 1024 * 1024 else { return nil }
        var compressed: UInt32 = 0, unpacked: UInt32 = 0
        if section >= "TEXB0002" {
            guard let c = u32(), let n = u32(), c <= 1, n <= 256 * 1024 * 1024 else { return nil }
            compressed = c; unpacked = n
        }
        guard let length = u32(), Int(length) <= data.count - cursor else { return nil }
        var bytes = Array(data[cursor..<cursor+Int(length)])
        if compressed == 1 {
            guard let decoded = Self.decodeLZ4(bytes, size: Int(unpacked)) else { return nil }
            bytes = decoded
        }
        return Mip(format: Int(format), width: Int(w), height: Int(h),
                   contentWidth: min(Int(cw), Int(w)), contentHeight: min(Int(ch), Int(h)),
                   encodedFormat: encoded, bytes: bytes)
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
        guard extractVideoData() == nil, let mip = firstMip() else { return nil }
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
