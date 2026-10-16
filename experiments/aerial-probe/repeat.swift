import AVFoundation
import Foundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
// Repeat the short pattern to a 3-minute silent aerial asset.
let asset = AVURLAsset(url: url)
let composition = AVMutableComposition()
let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
let video = asset.tracks(withMediaType: .video)[0]
let duration = asset.duration
var cursor = CMTime.zero
for _ in 0..<Int(ceil(180 / duration.seconds)) {
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
