import AVFoundation
import CoreGraphics
import Foundation

let url = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: url)
let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: 200, AVVideoHeightKey: 800
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
    sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                 kCVPixelBufferWidthKey as String: 200,
                                 kCVPixelBufferHeightKey as String: 800])
writer.add(input)
guard writer.startWriting() else { fatalError("Cannot start encoder: \(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)
for frame in 0..<90 {
    while !input.isReadyForMoreMediaData {
        guard writer.status == .writing else { fatalError("Encoder failed") }
        Thread.sleep(forTimeInterval: 0.005)
    }
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer) == kCVReturnSuccess,
          let buffer else { fatalError("Cannot allocate frame") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 200, height: 800,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    ctx.setFillColor(CGColor(red: 0.03, green: 0.15, blue: 0.3, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 800))
    ctx.setFillColor(CGColor(red: 0.1, green: 0.9, blue: 0.75, alpha: 1))
    let offset = CGFloat(frame) / 90 * 200
    for y in stride(from: -200, through: 1000, by: 200) {
        ctx.fillEllipse(in: CGRect(x: 50, y: CGFloat(y) + offset, width: 100, height: 100))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
        fatalError("Frame write failed")
    }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fatalError("Encode failed: \(String(describing: writer.error))") }
print("Generated 3-second silent H.264 loop: \(url.path)")
