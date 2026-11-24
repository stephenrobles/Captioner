import AVFoundation
import Foundation
import VideoToolbox

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

/// What a captions-only export is encoded with: both keep the transparent background.
nonisolated enum CaptionsOnlyFormat: String, Codable, CaseIterable, Sendable {
    case proRes4444, hevcWithAlpha

    var title: String {
        switch self {
        case .proRes4444: "ProRes 4444 (best for editing)"
        case .hevcWithAlpha: "HEVC with transparency (smaller files)"
        }
    }

    var codecType: AVVideoCodecType {
        switch self {
        case .proRes4444: .proRes4444
        case .hevcWithAlpha: .hevcWithAlpha
        }
    }

    /// The other format, for a device that cannot write this one.
    var fallback: CaptionsOnlyFormat {
        switch self {
        case .proRes4444: .hevcWithAlpha
        case .hevcWithAlpha: .proRes4444
        }
    }
}

/// Writes a movie with the captions burned in. Only the video is re-encoded, at the source
/// resolution, frame rate and roughly the source bit rate; audio tracks are copied sample for
/// sample (re-encoded to AAC only when the original format cannot live in an MP4).
///
/// With `captionsOnly`, the composition draws the captions over nothing (see
/// `CaptionComposition.make(info:overlay:captionsOnly:)`) and the file is a QuickTime movie with
/// an alpha channel and no audio, frame for frame as long as the source, to lay over it in a
/// video editor.
nonisolated enum VideoExporter {
    static func export(sourceURL: URL, composition: AVVideoComposition, to url: URL, codec: ExportCodec,
                       captionsOnly: CaptionsOnlyFormat? = nil,
                       timeRange: CMTimeRange? = nil, progress: @escaping @Sendable (Double) -> Void) async throws {
        // A private asset instance: never the one the preview player is using.
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptionerError.noVideoTrack
        }
        let audioTracks = captionsOnly == nil ? try await enabledAudioTracks(of: asset) : []
        let (duration, metadata) = try await asset.load(.duration, .metadata)
        let (dataRate, frameRate, timeScale) = try await videoTrack.load(.estimatedDataRate, .nominalFrameRate, .naturalTimeScale)
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
        let size = composition.renderSize
        let fps = frameRate > 1 ? Double(frameRate) : 30
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        if let captionsOnly {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            // ProRes 4444 where the device can write it, HEVC with alpha where it can't (and the other way round).
            let candidates = [captionsOnly, captionsOnly.fallback].filter { canEncode($0, size: size) }
                .map { captionsOnlySettings(format: $0, size: size, fps: fps) }
            guard let settings = candidates.first(where: { writer.canApply(outputSettings: $0, forMediaType: .video) }) else {
                throw CaptionerError.exportFailed("this device can't encode video with transparency at this size")
            }
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            videoInput.expectsMediaDataInRealTime = false
            // Keep the source's own time scale, so every frame starts exactly where its frame of
            // the video does (the writer's default of 600 can't hold 29.97 fps).
            if timeScale > 0 {
                videoInput.mediaTimeScale = timeScale
                writer.movieTimeScale = timeScale
            }
            guard writer.canAdd(videoInput) else { throw CaptionerError.exportFailed("this device can't encode video with transparency at this size") }
        } else {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true
            writer.metadata = metadata
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(codec: codec, size: size, fps: fps, sourceDataRate: Double(dataRate)))
            videoInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoInput) else { throw CaptionerError.exportFailed("this Mac can't encode \(codec == .hevc ? "HEVC" : "H.264") at this size") }
        }
        writer.add(videoInput)

        var pumps: [(output: AVAssetReaderOutput, input: AVAssetWriterInput)] = [(videoOutput, videoInput)]
        for track in audioTracks {
            let descriptions = try await track.load(.formatDescriptions)
            let passthrough = descriptions.allSatisfy(fitsInMP4)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: passthrough ? nil : pcmSettings(matching: descriptions.first))
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

    /// Settings for the captions on a transparent background. Neither codec is given a bit rate:
    /// ProRes has none to set, and HEVC is asked for a quality so that the mostly empty frames
    /// cost almost nothing. Its alpha is kept at full quality: anything less left a stray pixel
    /// of 1/255 opacity behind for half a second after a caption had gone. The colors are tagged
    /// Rec. 709, which is what the compositor renders.
    private static func captionsOnlySettings(format: CaptionsOnlyFormat, size: CGSize, fps: Double) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: format.codecType,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if format == .hevcWithAlpha {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoQualityKey: 0.9,
                kVTCompressionPropertyKey_TargetQualityForAlpha as String: 1.0,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
            ]
        }
        return settings
    }

    /// Whether this device has an encoder for `format` at `size`. iPhones and iPads differ here
    /// (ProRes most of all), so ask VideoToolbox instead of going by the model.
    static func canEncode(_ format: CaptionsOnlyFormat, size: CGSize) -> Bool {
        let codec: CMVideoCodecType = format == .proRes4444 ? kCMVideoCodecType_AppleProRes4444 : kCMVideoCodecType_HEVCWithAlpha
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height), codecType: codec,
                                                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { return false }
        VTCompressionSessionInvalidate(session)
        return true
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

    /// The audio tracks that play by default. iPhone spatial recordings carry a second, disabled
    /// track in Apple's positional codec (four channels); copying it would duplicate the sound,
    /// and iOS can't fold four channels into a stereo AAC encoder, which failed the whole export.
    private static func enabledAudioTracks(of asset: AVAsset) async throws -> [AVAssetTrack] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var enabled: [AVAssetTrack] = []
        for track in tracks where try await track.load(.isEnabled) {
            enabled.append(track)
        }
        return enabled.isEmpty ? tracks : enabled
    }

    /// Decoded audio for the AAC encoder: the source's rate, and no more than two channels.
    private static func pcmSettings(matching description: CMFormatDescription?) -> [String: Any] {
        var settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM]
        if let description, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee, asbd.mChannelsPerFrame > 2 {
            settings[AVNumberOfChannelsKey] = 2
        }
        return settings
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
    /// A captions-only export is `<name> Captions.mov`.
    static func outputURL(for source: URL, in folder: URL?, captionsOnly: Bool = false) -> URL {
        let directory = folder ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + (captionsOnly ? " Captions" : " Captioned")
        let ext = captionsOnly ? "mov" : "mp4"
        var candidate = directory.appending(path: "\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
