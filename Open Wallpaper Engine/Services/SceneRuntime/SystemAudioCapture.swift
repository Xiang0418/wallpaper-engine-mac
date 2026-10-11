import AVFoundation
import ScreenCaptureKit

/// One audio-only output for the application. No screen frames are delivered,
/// stored, or displayed. Each stream owns its sink so late callbacks cannot
/// contaminate a replacement stream.
final class SystemAudioCapture: NSObject, SCStreamDelegate {
    var statusChanged: ((String) -> Void)?
    private var stream: SCStream?
    private var sink: SystemAudioSpectrumSink?
    private var transition: Task<Void, Never>?
    private var generation = UUID()
    private var enabled = false

    func setEnabled(_ value: Bool, retry: Bool = false) {
        guard value != enabled || retry else { return }
        enabled = value
        let token = UUID(); generation = token
        sink?.reset(); sink = nil
        let preceding = transition
        preceding?.cancel()
        transition = Task { @MainActor [weak self] in
            await preceding?.value
            guard let self else { return }
            if let old = self.stream {
                self.stream = nil
                try? await old.stopCapture()
            }
            guard self.generation == token else { return }
            guard value else { self.statusChanged?(String(localized: "External audio is off")); return }
            self.statusChanged?(String(localized: "Requesting system audio access…"))
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard self.generation == token, !Task.isCancelled else { return }
                guard let display = content.displays.first else { throw CaptureError.noDisplay }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.width = 2; configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                configuration.queueDepth = 3
                configuration.showsCursor = false
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 48000; configuration.channelCount = 2
                let sink = SystemAudioSpectrumSink()
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
                self.stream = stream
                try await stream.startCapture()
                guard self.generation == token, !Task.isCancelled else { return }
                self.sink = sink
                self.statusChanged?(String(localized: "Listening to other apps"))
            } catch {
                if let old = self.stream { self.stream = nil; try? await old.stopCapture() }
                guard self.generation == token else { return }
                self.sink = nil
                self.statusChanged?(String(localized: "System audio unavailable. Check Screen & System Audio Recording permission, then retry.") + " (\(error.localizedDescription))")
            }
        }
    }

    func snapshot() -> [Float] { sink?.snapshot() ?? Array(repeating: 0, count: 64) }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil; self.sink?.reset(); self.sink = nil
            self.statusChanged?(String(localized: "System audio stopped. Check recording permission, then retry.") + " (\(error.localizedDescription))")
        }
    }

    private enum CaptureError: Error { case noDisplay }
}

final class SystemAudioSpectrumSink: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "wallpaper.external-audio", qos: .utility)
    private let analyzer = SceneAudioSpectrum()
    private let lock = NSLock()
    private var lastSample: TimeInterval = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(buffer), CMSampleBufferDataIsReady(buffer),
              let description = CMSampleBufferGetFormatDescription(buffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { return }
        let frames = CMSampleBufferGetNumSamples(buffer)
        guard frames > 0, frames <= 8192, format.mChannelsPerFrame > 0, format.mChannelsPerFrame <= 8 else { return }
        let bufferCount = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int(format.mChannelsPerFrame) : 1
        let list = AudioBufferList.allocate(maximumBuffers: bufferCount)
        defer { list.unsafeMutablePointer.deallocate() }
        var block: CMBlockBuffer?
        let result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(buffer, bufferListSizeNeededOut: nil,
            bufferListOut: list.unsafeMutablePointer, bufferListSize: MemoryLayout<AudioBufferList>.size + (bufferCount - 1) * MemoryLayout<AudioBuffer>.stride,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &block)
        guard result == noErr else { return }
        var channels: [[Float]] = []
        for audio in list {
            let count = Int(audio.mNumberChannels)
            guard count > 0, let data = audio.mData, Int(audio.mDataByteSize) >= frames * count * 4 else { return }
            let values = data.assumingMemoryBound(to: Float.self)
            for channel in 0..<count {
                channels.append((0..<frames).map { values[$0 * count + channel] })
            }
        }
        consume(channels: channels, at: ProcessInfo.processInfo.systemUptime)
    }

    /// Choose the highest-energy channel, avoiding cancellation of antiphase
    /// stereo while keeping the existing 64-band mono shader contract.
    func consume(channels: [[Float]], at time: TimeInterval) {
        guard let strongest = channels.filter({ !$0.isEmpty && $0.count <= 8192 }).max(by: {
            $0.reduce(0.0) { $0 + Double($1 * $1) } < $1.reduce(0.0) { $0 + Double($1 * $1) }
        }), strongest.allSatisfy(\.isFinite) else { return }
        lock.lock(); defer { lock.unlock() }
        if time - lastSample > 0.3 { analyzer.reset() }
        analyzer.consume(strongest); lastSample = time
    }

    func snapshot(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard lastSample > 0, time - lastSample < 0.3 else { return Array(repeating: 0, count: 64) }
        return analyzer.snapshot()
    }

    func reset() { lock.lock(); defer { lock.unlock() }; lastSample = 0; analyzer.reset() }
}
