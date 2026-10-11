import AppKit
import AVFoundation
import ScreenCaptureKit

final class FakeAudio: ExternalAudioCapturing {
    var statusChanged: ((String) -> Void)?
    var changes: [Bool] = []
    func setEnabled(_ value: Bool, retry: Bool) { changes.append(value) }
    func snapshot() -> [Float] { Array(repeating: 0.5, count: 64) }
}

@main struct ExternalMediaTests {
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label); print("PASS: " + label)
    }
    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let suite = "ExternalMediaTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let audio = FakeAudio()
        let service = ExternalAudioService(defaults: defaults, audio: audio)
        let first = UUID(), second = UUID()
        service.setConsumer(first, active: true)
        check(audio.changes.isEmpty, "Opt-in default does not request recording")
        service.systemAudioEnabled = true
        service.setConsumer(second, active: true)
        check(audio.changes == [true], "Two displays share one capture")
        service.setConsumer(first, active: false)
        check(audio.changes == [true], "Pausing one display preserves the active display")
        service.setConsumer(second, active: false)
        check(audio.changes == [true, false], "Last paused or removed display stops capture")
        service.setConsumer(first, active: true)
        check(audio.changes == [true, false, true], "Resuming reconnects once")
        service.retry()
        check(audio.changes == [true, false, true, true], "Explicit retry restarts capture")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        check(audio.changes.last == false, "System sleep releases capture")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        check(audio.changes.last == true, "System wake reconnects active scenes")
        check(defaults.bool(forKey: "ExternalMedia.audio"), "Audio preference persists")
        let samples = (0..<1024).map { sin(2 * Float.pi * 32 * Float($0) / 1024) * 0.5 }
        let sink = SystemAudioSpectrumSink()
        sink.consume(channels: [samples, samples.map { -$0 }], at: 10)
        check(sink.snapshot(at: 10.01).max()! > 0.1, "Antiphase stereo produces a real spectrum")
        check(sink.snapshot(at: 10.4).allSatisfy { $0 == 0 }, "Stopped callbacks cannot leave a frozen spectrum")
        sink.consume(channels: [Array(repeating: 0, count: 1024)], at: 11)
        check(sink.snapshot(at: 11.01).allSatisfy { $0 == 0 }, "Silence after a gap clears old energy")
        sink.consume(channels: [samples], at: 12); sink.reset()
        check(sink.snapshot(at: 12.01).allSatisfy { $0 == 0 }, "Stopping capture clears PCM and spectrum")

        // Exercise the actual CoreMedia callback, both planar and interleaved.
        for interleaved in [false, true] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: interleaved)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
            pcm.frameLength = 1024
            for frame in 0..<1024 {
                if interleaved { pcm.floatChannelData![0][frame*2] = samples[frame]; pcm.floatChannelData![0][frame*2+1] = -samples[frame] }
                else { pcm.floatChannelData![0][frame] = samples[frame]; pcm.floatChannelData![1][frame] = -samples[frame] }
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            var buffer: CMSampleBuffer?
            check(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                      formatDescription: format.formatDescription, sampleCount: 1024, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer) == noErr, "Create CoreMedia PCM fixture")
            check(CMSampleBufferSetDataBufferFromAudioBufferList(buffer!, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                               flags: 0, bufferList: pcm.audioBufferList) == noErr, "Attach PCM data")
            CMSampleBufferSetDataReady(buffer!)
            // Stream is unused by the sink; a disconnected object requires no TCC permission.
            let stream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
            sink.reset(); sink.stream(stream, didOutputSampleBuffer: buffer!, of: .audio)
            check(sink.snapshot().max()! > 0.1, "CoreMedia conversion \(interleaved ? "interleaved" : "planar")")
        }
        service.shutdown()
        check(audio.changes.last == false, "App shutdown releases capture")
        print("External audio tests passed")
    }
}
