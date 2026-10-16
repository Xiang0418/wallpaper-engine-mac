import AVFoundation
import CoreAudio

/// Audio-only capture. Never creates a display stream or falls back to screen capture.
final class SystemAudioCapture {
    var statusChanged: ((String) -> Void)?
    private var session: AnyObject?
    private var sink: SystemAudioSpectrumSink?
    private var enabled = false

    func setEnabled(_ value: Bool, retry: Bool = false) {
        guard value != enabled || retry else { return }
        enabled = value
        stop()
        guard value else { statusChanged?(String(localized: "External audio is off")); return }
        guard #available(macOS 14.2, *) else {
            statusChanged?(String(localized: "Audio-only capture requires macOS 14.2 or later. Screen capture will not be used.")); return
        }
        statusChanged?(String(localized: "Requesting system audio access…"))
        do {
            let sink = SystemAudioSpectrumSink()
            sink.didReceiveSignal = { [weak self, weak sink] in
                DispatchQueue.main.async { [weak self, weak sink] in
                    guard let self, let sink, self.enabled, self.sink === sink else { return }
                    self.statusChanged?(String(localized: "Receiving system audio (audio only)"))
                }
            }
            let session = try ProcessTapSession(sink: sink)
            self.session = session; self.sink = sink
            statusChanged?(String(localized: "Listening to other apps (audio only)"))
        } catch {
            statusChanged?(String(localized: "System audio unavailable. Allow system audio recording in Privacy & Security, then retry.") + " (\(error.localizedDescription))")
        }
    }

    private func stop() {
        if #available(macOS 14.2, *) { (session as? ProcessTapSession)?.stop() }
        session = nil; sink?.reset(); sink = nil
    }
    func snapshot() -> [Float] { sink?.snapshot() ?? Array(repeating:0,count:64) }
    deinit { stop() }
}

@available(macOS 14.2, *)
private final class ProcessTapSession {
    private var tap: AudioObjectID = kAudioObjectUnknown
    private var device: AudioObjectID = kAudioObjectUnknown
    private var io: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "wallpaper.audio-tap", qos: .userInitiated)

    init(sink: SystemAudioSpectrumSink) throws {
        do {
            var pid = getpid(), process: AudioObjectID = kAudioObjectUnknown
            var address = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyTranslatePIDToProcessObject,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process), "Resolve own audio process")
            guard process != kAudioObjectUnknown else { throw NSError(domain:"ProcessTap",code:-1,userInfo:[NSLocalizedDescriptionKey:"Own audio process is unavailable"]) }
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses:[process])
            description.name = "Wallpaper audio spectrum"
            description.uuid = UUID(); description.isPrivate = true; description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap), "Create audio tap")
            var format = AudioStreamBasicDescription()
            address.mSelector = kAudioTapPropertyFormat
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "Read tap format")
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else {
                throw NSError(domain:"ProcessTap",code:-2,userInfo:[NSLocalizedDescriptionKey:"Unsupported audio tap PCM format"])
            }
            let specification: [String:Any] = [
                kAudioAggregateDeviceNameKey:"Wallpaper Audio Tap",
                kAudioAggregateDeviceUIDKey:UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey:true,
                kAudioAggregateDeviceTapAutoStartKey:true,
                kAudioAggregateDeviceTapListKey:[[kAudioSubTapUIDKey:description.uuid.uuidString,kAudioSubTapDriftCompensationKey:true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(specification as CFDictionary, &device), "Create audio-only device")
            try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, queue) { _, input, _, _, _ in
                sink.consume(bufferList: input)
            }, "Create audio callback")
            try check(AudioDeviceStart(device, io), "Start audio tap")
        } catch { stop(); throw error }
    }
    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw NSError(domain:"CoreAudio",code:Int(status),userInfo:[NSLocalizedDescriptionKey:"\(operation): OSStatus \(status)"]) }
    }
    func stop() {
        if device != kAudioObjectUnknown {
            if let io { AudioDeviceStop(device, io); AudioDeviceDestroyIOProcID(device, io) }
            io = nil; AudioHardwareDestroyAggregateDevice(device); device = kAudioObjectUnknown
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = kAudioObjectUnknown }
    }
    deinit { stop() }
}

final class SystemAudioSpectrumSink {
    private let analyzer = SceneAudioSpectrum()
    private let lock = NSLock()
    private var lastSample: TimeInterval = 0
    var didReceiveSignal: (() -> Void)?
    private var reportedSignal = false

    func consume(bufferList: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:bufferList))
        var channels: [[Float]] = []
        for buffer in buffers {
            let count = Int(buffer.mNumberChannels)
            guard count > 0, count <= 8, let data = buffer.mData,
                  buffer.mDataByteSize % UInt32(count * 4) == 0 else { return }
            let frames = Int(buffer.mDataByteSize) / (count * 4)
            guard frames > 0, frames <= 8192 else { return }
            let values = data.assumingMemoryBound(to:Float.self)
            for channel in 0..<count { channels.append((0..<frames).map { values[$0*count+channel] }) }
        }
        consume(channels:channels, at:ProcessInfo.processInfo.systemUptime)
    }

    /// Choose the highest-energy channel, avoiding cancellation of antiphase
    /// stereo while keeping the existing 64-band mono shader contract.
    func consume(channels: [[Float]], at time: TimeInterval) {
        guard let strongest = channels.filter({ !$0.isEmpty && $0.count <= 8192 }).max(by: {
            $0.reduce(0.0) { $0 + Double($1 * $1) } < $1.reduce(0.0) { $0 + Double($1 * $1) }
        }), strongest.allSatisfy(\.isFinite) else { return }
        lock.lock()
        let notify = !reportedSignal && strongest.contains { abs($0) > 0.00001 }
        if notify { reportedSignal = true }
        if time - lastSample > 0.3 { analyzer.reset() }
        analyzer.consume(strongest); lastSample = time
        lock.unlock()
        if notify { didReceiveSignal?() }
    }

    func snapshot(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard lastSample > 0, time - lastSample < 0.3 else { return Array(repeating: 0, count: 64) }
        return analyzer.snapshot()
    }

    func reset() { lock.lock(); defer { lock.unlock() }; lastSample = 0; reportedSignal = false; analyzer.reset() }
}
