import AVFoundation
import Accelerate

/// An actual PCM spectrum, never synthetic animation. The playback owner can feed
/// PCM into consume() instead of creating a second player when phase one is merged.
final class SceneAudioSpectrum {
    private let lock = NSLock()
    private let count = 1024
    private let transform = vDSP_DFT_zop_CreateSetup(nil, 1024, .FORWARD)!
    private var pending: [Float] = []
    private var bins = [Float](repeating: 0, count: 64)
    deinit { vDSP_DFT_DestroySetup(transform) }

    func consume(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        pending.append(contentsOf: samples)
        while pending.count >= count {
            var real = Array(pending.prefix(count))
            pending.removeFirst(count)
            for i in 0..<count { real[i] *= 0.5 - 0.5 * cos(2 * .pi * Float(i) / Float(count - 1)) }
            let imaginary = [Float](repeating: 0, count: count)
            var outReal = imaginary, outImaginary = imaginary
            vDSP_DFT_Execute(transform, real, imaginary, &outReal, &outImaginary)
            for band in 0..<64 {
                let low = max(1, Int(pow(512.0, Double(band) / 64)))
                let high = min(512, max(low + 1, Int(pow(512.0, Double(band + 1) / 64))))
                var peak: Float = 0
                for i in low..<high { peak = max(peak, hypot(outReal[i], outImaginary[i]) * 4 / Float(count)) }
                bins[band] = min(1, max(peak, bins[band] * 0.8))
            }
        }
    }

    func snapshot() -> [Float] { lock.lock(); defer { lock.unlock() }; return bins }

    func reset() {
        lock.lock(); pending.removeAll(); bins = Array(repeating:0,count:64); lock.unlock()
    }
}

/// Reads a bounded PCM window on a worker queue at the existing AVAudioPlayer's
/// current time. AVAudioPlayer has no output tap: decoding is analysis-only and
/// never creates another audio output or changes the playback owner's timeline.
final class SceneAudioSpectrumSource {
    private let file: AVAudioFile
    private let analyzer = SceneAudioSpectrum()
    private let queue = DispatchQueue(label:"wallpaper.spectrum.decode",qos:.utility)
    private let lock = NSLock()
    private var busy = false
    private var stopped = false
    private var lastFrame: AVAudioFramePosition = -1

    init(url: URL) throws { file = try AVAudioFile(forReading:url) }

    func snapshot(at time: TimeInterval, volume: Float, playing: Bool) -> [Float] {
        guard playing, volume > 0 else { return Array(repeating:0,count:64) }
        let frame = AVAudioFramePosition(max(0,time) * file.processingFormat.sampleRate)
        lock.lock()
        let shouldRead = !busy && !stopped && abs(frame-lastFrame) >= 1024
        if shouldRead { busy = true; lastFrame = frame }
        lock.unlock()
        if shouldRead {
            queue.async { [weak self] in
                guard let self else { return }
                defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
                guard let buffer = AVAudioPCMBuffer(pcmFormat:self.file.processingFormat,frameCapacity:1024) else { return }
                do {
                    self.file.framePosition = min(frame,self.file.length)
                    try self.file.read(into:buffer,frameCount:1024)
                    guard let channels=buffer.floatChannelData else { return }
                    let c=Int(buffer.format.channelCount), n=Int(buffer.frameLength)
                    guard c > 0 else { return }
                    var mono=[Float](repeating:0,count:1024)
                    for channel in 0..<c { for i in 0..<n { mono[i] += channels[channel][i] / Float(c) } }
                    self.analyzer.consume(mono)
                } catch { self.analyzer.reset() }
            }
        }
        return analyzer.snapshot().map { min(1,$0 * volume) }
    }

    func stop() { lock.lock(); stopped=true; lock.unlock(); analyzer.reset() }
}
