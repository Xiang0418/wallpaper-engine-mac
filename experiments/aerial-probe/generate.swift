import AVFoundation
import CoreGraphics
import CoreText
import Foundation

let url = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: url)
let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.hevc,
    AVVideoWidthKey: 1280, AVVideoHeightKey: 720
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
    sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                 kCVPixelBufferWidthKey as String: 1280,
                                 kCVPixelBufferHeightKey as String: 720])
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
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 1280, height: 720,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    ctx.setFillColor(CGColor(red: 0.03, green: 0.15, blue: 0.3, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
    ctx.setFillColor(CGColor(red: 0.1, green: 0.9, blue: 0.75, alpha: 1))
    let offset = CGFloat(frame) / 90 * 240
    for x in stride(from: -240, through: 1520, by: 240) {
        ctx.fillEllipse(in: CGRect(x: CGFloat(x) + offset, y: 100, width: 100, height: 100))
        ctx.fillEllipse(in: CGRect(x: CGFloat(x) + offset, y: 520, width: 100, height: 100))
    }
    let label = NSAttributedString(string: "AERIAL VIDEO TEST", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 54, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
    ])
    ctx.textPosition = CGPoint(x: 320, y: 350)
    CTLineDraw(CTLineCreateWithAttributedString(label), ctx)
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
print("Generated 3-second silent HEVC loop: \(url.path)")

// Repeat the short pattern to a 3-minute silent aerial asset.
let asset = AVURLAsset(url: url)
let composition = AVMutableComposition()
let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
let video = asset.tracks(withMediaType: .video)[0]
let duration = asset.duration
var cursor = CMTime.zero
for _ in 0..<60 {
    try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: video, at: cursor)
    cursor = cursor + duration
}
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.removeItem(at: output)
let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
exporter.outputURL = output
exporter.outputFileType = .mov
exporter.shouldOptimizeForNetworkUse = true
let finished = DispatchSemaphore(value: 0)
exporter.exportAsynchronously { finished.signal() }
finished.wait()
guard exporter.status == .completed else { fatalError("Export failed: \(String(describing: exporter.error))") }
let result = AVURLAsset(url: output)
guard result.tracks(withMediaType: .audio).isEmpty, result.duration.seconds >= 179 else { fatalError("Invalid output") }
print("Validated \(result.duration.seconds) seconds, no audio: \(output.path)")
