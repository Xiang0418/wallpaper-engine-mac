import Foundation
import AVFoundation
import VideoToolbox

final class LockScreenCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

/// Main10 + temporal sublayers are required by the system Aerial poster/ramp-down path.
/// Encode one source cycle, then repeat compressed samples; no third-party executable is used.
enum LockScreenVideoEncoder {
    static func encode(source: URL, output: URL, cancellation: LockScreenCancellation) async throws {
        let fm = FileManager.default
        let short = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? fm.removeItem(at: short) }
        do {
            let asset = AVURLAsset(url: source)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw LockScreenFailure("This wallpaper has no video track.")
            }
            let duration = try await asset.load(.duration)
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let rate = try await track.load(.nominalFrameRate)
            guard duration.seconds.isFinite, duration.seconds > 0, size.width > 0, size.height > 0 else {
                throw LockScreenFailure("The source video is invalid.")
            }
            try cancellation.check()
            try encodeCycle(asset: asset, track: track, size: size, transform: transform,
                            fps: rate > 0 ? Double(rate) : 30, output: short, cancellation: cancellation)
            try cancellation.check()
            let encoded = AVURLAsset(url: short)
            guard let encodedTrack = try await encoded.loadTracks(withMediaType: .video).first else {
                throw LockScreenFailure("No encoded video was produced.")
            }
            let length = try await encoded.load(.duration)
            guard length.seconds.isFinite, length.seconds > 0 else { throw LockScreenFailure("Invalid encoded duration.") }
            let composition = AVMutableComposition()
            guard let destination = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw LockScreenFailure("Cannot prepare the Aerial movie.")
            }
            destination.preferredTransform = transform
            var time = CMTime.zero
            // At least three minutes, retaining long source clips in full.
            for _ in 0..<max(1, Int(ceil(180 / length.seconds))) {
                try cancellation.check()
                try destination.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: encodedTrack, at: time)
                time = time + length
            }
            guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                throw LockScreenFailure("Cannot export the Aerial movie.")
            }
            export.outputURL = output; export.outputFileType = .mov
            export.shouldOptimizeForNetworkUse = true
            try waitForExport(export, cancellation: cancellation)
            guard export.status == .completed else { throw export.error ?? LockScreenFailure("Aerial export failed.") }
            try cancellation.check()
            let result = AVURLAsset(url: output)
            let audio = try await result.loadTracks(withMediaType: .audio)
            let resultDuration = try await result.load(.duration)
            guard audio.isEmpty, resultDuration.seconds >= 179 else { throw LockScreenFailure("Aerial output validation failed.") }
        } catch {
            try? fm.removeItem(at: output)
            throw error
        }
    }

    private static func waitForExport(_ export: AVAssetExportSession, cancellation: LockScreenCancellation) throws {
        let completed = DispatchSemaphore(value: 0)
        export.exportAsynchronously { completed.signal() }
        var cancelled: Error?
        while completed.wait(timeout: .now() + 0.1) == .timedOut {
            do { try cancellation.check() } catch { cancelled = error; export.cancelExport() }
        }
        if let cancelled { throw cancelled }
    }

    private static func encodeCycle(asset: AVAsset, track: AVAssetTrack, size: CGSize, transform: CGAffineTransform,
                                    fps: Double, output: URL, cancellation: LockScreenCancellation) throws {
        let sink = try EncodedSink(output: output, transform: transform, cancellation: cancellation)
        let callback: VTCompressionOutputCallback = { context, _, status, _, sample in
            guard let context else { return }
            let sink = Unmanaged<EncodedSink>.fromOpaque(context).takeUnretainedValue()
            sink.accept(status: status, sample: sample)
        }
        var optional: VTCompressionSession?
        let code = VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: callback,
            refcon: Unmanaged.passUnretained(sink).toOpaque(), compressionSessionOut: &optional)
        guard code == noErr, let session = optional else { throw LockScreenFailure("HEVC encoder is unavailable (\(code)).") }
        defer { VTCompressionSessionInvalidate(session) }
        func set(_ key: CFString, _ value: CFTypeRef) throws {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else { throw LockScreenFailure("Aerial encoding option is unavailable (\(status)).") }
        }
        try set(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel)
        try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanTrue)
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: Int(fps * 5)))
        try set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: 12_000_000))
        try set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        try set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        try set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        try set(kVTCompressionPropertyKey_AllowTemporalCompression, kCFBooleanTrue)
        try set(kVTCompressionPropertyKey_BaseLayerFrameRate, NSNumber(value: fps / 2))
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else { throw LockScreenFailure("Cannot start HEVC encoding.") }
        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
        frames.alwaysCopiesSampleData = false
        reader.add(frames)
        guard reader.startReading() else { throw reader.error ?? LockScreenFailure("Cannot decode this video.") }
        defer { reader.cancelReading() }
        while let sample = frames.copyNextSampleBuffer() {
            try cancellation.check()
            try sink.check()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw LockScreenFailure("Missing decoded frame.") }
            var duration = CMSampleBufferGetDuration(sample)
            if !duration.isNumeric || duration.seconds <= 0 { duration = CMTime(seconds: 1 / fps, preferredTimescale: 60000) }
            let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer,
                presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample), duration: duration,
                frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
            guard status == noErr else { throw LockScreenFailure("Video encoding failed (\(status)).") }
        }
        guard reader.status == .completed else { throw reader.error ?? LockScreenFailure("Video decoding was interrupted.") }
        guard VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) == noErr else {
            throw LockScreenFailure("Could not finish video encoding.")
        }
        try sink.finish()
        withExtendedLifetime(sink) {}
    }

    private final class EncodedSink {
        let writer: AVAssetWriter
        let transform: CGAffineTransform
        let cancellation: LockScreenCancellation
        let lock = NSLock()
        var input: AVAssetWriterInput?
        var failure: Error?
        init(output: URL, transform: CGAffineTransform, cancellation: LockScreenCancellation) throws {
            writer = try AVAssetWriter(outputURL: output, fileType: .mov)
            self.transform = transform; self.cancellation = cancellation
        }
        func check() throws { lock.lock(); defer { lock.unlock() }; if let failure { throw failure } }
        func accept(status: OSStatus, sample: CMSampleBuffer?) {
            lock.lock(); defer { lock.unlock() }
            guard failure == nil else { return }
            do {
                try cancellation.check()
                guard status == noErr, let sample, CMSampleBufferDataIsReady(sample),
                      let format = CMSampleBufferGetFormatDescription(sample) else {
                    throw LockScreenFailure("The encoder returned an invalid frame (\(status)).")
                }
                if input == nil {
                    let stream = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
                    stream.transform = transform
                    writer.add(stream)
                    guard writer.startWriting() else { throw writer.error ?? LockScreenFailure("Cannot write encoded video.") }
                    writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
                    input = stream
                }
                guard let input else { throw LockScreenFailure("Missing output stream.") }
                let deadline = Date().addingTimeInterval(30)
                while !input.isReadyForMoreMediaData {
                    try cancellation.check()
                    guard writer.status == .writing, Date() < deadline else {
                        throw writer.error ?? LockScreenFailure("Video writer timed out.")
                    }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                guard input.append(sample) else { throw writer.error ?? LockScreenFailure("Cannot append encoded frame.") }
            } catch { failure = error }
        }
        func finish() throws {
            try check(); try cancellation.check()
            guard let input else { throw LockScreenFailure("The encoder produced no frames.") }
            input.markAsFinished()
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            while done.wait(timeout: .now() + 0.1) == .timedOut {
                do { try cancellation.check() } catch { writer.cancelWriting(); throw error }
            }
            guard writer.status == .completed else { throw writer.error ?? LockScreenFailure("Could not finish encoded movie.") }
        }
        deinit { if writer.status == .writing { writer.cancelWriting() } }
    }
}
