import AVFoundation
import Foundation

nonisolated enum ExportCodec: String, Codable, CaseIterable, Sendable {
    case h264, hevc

    var title: String {
        switch self {
        case .h264: "H.264 (most compatible)"
        case .hevc: "HEVC (smaller files)"
        }
    }

    var codecType: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        }
    }
}

/// Writes a movie with the captions burned in. Only the video is re-encoded, at the source
/// resolution, frame rate and roughly the source bit rate; audio tracks are copied sample for
/// sample (re-encoded to AAC only when the original format cannot live in an MP4).
nonisolated enum VideoExporter {
    static func export(sourceURL: URL, composition: AVVideoComposition, to url: URL, codec: ExportCodec,
                       timeRange: CMTimeRange? = nil, progress: @escaping @Sendable (Double) -> Void) async throws {
        // A private asset instance: never the one the preview player is using.
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptionerError.noVideoTrack
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let (duration, metadata) = try await asset.load(.duration, .metadata)
        let (dataRate, frameRate) = try await videoTrack.load(.estimatedDataRate, .nominalFrameRate)
        let range = timeRange ?? CMTimeRange(start: .zero, duration: duration)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw CaptionerError.exportFailed("the video can't be read") }
        reader.add(videoOutput)

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = metadata

        let size = composition.renderSize
        let fps = frameRate > 1 ? Double(frameRate) : 30
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(codec: codec, size: size, fps: fps, sourceDataRate: Double(dataRate)))
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw CaptionerError.exportFailed("this Mac can't encode \(codec == .hevc ? "HEVC" : "H.264") at this size") }
        writer.add(videoInput)

        var pumps: [(output: AVAssetReaderOutput, input: AVAssetWriterInput)] = [(videoOutput, videoInput)]
        for track in audioTracks {
            let descriptions = try await track.load(.formatDescriptions)
            let passthrough = descriptions.allSatisfy(fitsInMP4)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: passthrough ? nil : [AVFormatIDKey: kAudioFormatLinearPCM])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            let input: AVAssetWriterInput
            if passthrough {
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: descriptions.first)
            } else {
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings(matching: descriptions.first))
            }
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { continue }
            writer.add(input)
            pumps.append((output, input))
        }

        guard reader.startReading() else { throw reader.error ?? CaptionerError.exportFailed("the video can't be read") }
        guard writer.startWriting() else { throw writer.error ?? CaptionerError.exportFailed("the file can't be written") }
        writer.startSession(atSourceTime: range.start)

        let total = range.duration.seconds
        let start = range.start.seconds
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (index, pump) in pumps.enumerated() {
                    let reportsProgress = index == 0
                    group.addTask {
                        try await drive(pump.output, into: pump.input, writer: writer) { time in
                            if reportsProgress, total > 0 { progress(min(1, max(0, (time - start) / total))) }
                        }
                    }
                }
                try await group.waitForAll()
            }
        } onCancel: {
            reader.cancelReading()
        }

        if Task.isCancelled || reader.status == .cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw reader.error ?? CaptionerError.exportFailed("the video couldn't be read")
        }
        await writer.finishWriting()
        if writer.status == .failed {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? CaptionerError.exportFailed("the file couldn't be written")
        }
        progress(1)
    }

    /// One reader output feeding one writer input. AVFoundation's objects are used from the
    /// pump's own serial queue only, so sharing them with the callback is safe.
    private final class Pump: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let writer: AVAssetWriter
        var finished = false

        init(output: AVAssetReaderOutput, input: AVAssetWriterInput, writer: AVAssetWriter) {
            self.output = output
            self.input = input
            self.writer = writer
        }
    }

    /// Feeds one reader output into one writer input until the output runs dry.
    private static func drive(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, writer: AVAssetWriter,
                              onSample: @escaping @Sendable (TimeInterval) -> Void) async throws {
        let pump = Pump(output: output, input: input, writer: writer)
        let queue = DispatchQueue(label: "fm.beard.Captioner.export.\(output.mediaType.rawValue)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pump.input.requestMediaDataWhenReady(on: queue) {
                guard !pump.finished else { return }
                while pump.input.isReadyForMoreMediaData {
                    guard let sample = pump.output.copyNextSampleBuffer() else {
                        pump.input.markAsFinished()
                        pump.finished = true
                        continuation.resume()
                        return
                    }
                    onSample(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                    if !pump.input.append(sample) {
                        pump.input.markAsFinished()
                        pump.finished = true
                        continuation.resume(throwing: pump.writer.error ?? CaptionerError.exportFailed("a sample couldn't be written"))
                        return
                    }
                }
            }
        }
    }

    private static func videoSettings(codec: ExportCodec, size: CGSize, fps: Double, sourceDataRate: Double) -> [String: Any] {
        // Aim for the source's bit rate, within a floor that keeps captions crisp and a ceiling
        // that keeps a ProRes master from turning into an absurd H.264 file.
        let pixelsPerSecond = size.width * size.height * fps
        let floor = pixelsPerSecond * 0.08
        let ceiling = pixelsPerSecond * 0.4
        var bitrate = min(max(sourceDataRate, floor), ceiling)
        if codec == .hevc { bitrate *= 0.65 }
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(bitrate),
            AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
            AVVideoAllowFrameReorderingKey: true,
        ]
        if codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        return [
            AVVideoCodecKey: codec.codecType,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    /// Whether audio in this format can be copied straight into an MP4 file.
    private static func fitsInMP4(_ description: CMFormatDescription) -> Bool {
        switch CMFormatDescriptionGetMediaSubType(description) {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_ELD_SBR, kAudioFormatMPEG4AAC_ELD_V2, kAudioFormatMPEG4AAC_Spatial,
             kAudioFormatAppleLossless, kAudioFormatAC3, kAudioFormatEnhancedAC3, kAudioFormatMPEGLayer3, kAudioFormatFLAC, kAudioFormatOpus:
            true
        default:
            false
        }
    }

    private static func aacSettings(matching description: CMFormatDescription?) -> [String: Any] {
        var sampleRate = 48000.0
        var channels = 2
        if let description, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
            if asbd.mChannelsPerFrame > 0 { channels = min(Int(asbd.mChannelsPerFrame), 2) }
        }
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels > 1 ? 256_000 : 160_000,
        ]
    }

    /// `<name> Captioned.mp4` beside the original (or in `folder`), numbered if that already exists.
    static func outputURL(for source: URL, in folder: URL?) -> URL {
        let directory = folder ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + " Captioned"
        var candidate = directory.appending(path: base + ".mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(base) \(n).mp4")
            n += 1
        }
        return candidate
    }
}
