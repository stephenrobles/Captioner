import AVFoundation
import CoreImage
import Foundation

/// The current captions, style and placement for one video, shared between the main thread
/// (which edits it) and the compositor (which reads it for every frame).
nonisolated final class CaptionOverlay: @unchecked Sendable {
    private let lock = NSLock()
    private var current: RenderSnapshot

    init(snapshot: RenderSnapshot) {
        current = snapshot
    }

    var snapshot: RenderSnapshot {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// One instruction covers the whole movie: pass the source frame through, rotated upright, with
/// captions composited on top.
nonisolated final class CaptionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let trackID: CMPersistentTrackID
    let orientation: CGImagePropertyOrientation
    let overlay: CaptionOverlay

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, orientation: CGImagePropertyOrientation, overlay: CaptionOverlay) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.orientation = orientation
        self.overlay = overlay
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
    }
}

/// Composites captions over each frame. The caption picture only changes when the active word
/// changes (or while a word pops), so it is rendered once and reused across frames.
nonisolated final class CaptionCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private struct OverlayKey: Hashable {
        let snapshot: RenderSnapshot
        let captionID: UUID
        let activeIndex: Int?
        let visibleWords: Int
        let popStep: Int
        let width: Double
        let height: Double
    }

    private let queue = DispatchQueue(label: "fm.beard.Captioner.compositor", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false, .name: "Captioner"])
    private var cachedKey: OverlayKey?
    private var cachedImage: CIImage?

    private static let pixelAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]

    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.pixelAttributes }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.pixelAttributes }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            autoreleasepool {
                do {
                    try render(request)
                } catch {
                    request.finish(with: error)
                }
            }
        }
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) throws {
        guard let instruction = request.videoCompositionInstruction as? CaptionInstruction else {
            throw CompositorError.badInstruction
        }
        guard let source = request.sourceFrame(byTrackID: instruction.trackID) else {
            throw CompositorError.missingFrame
        }
        guard let output = request.renderContext.newPixelBuffer() else {
            throw CompositorError.noOutputBuffer
        }
        let size = request.renderContext.size
        let sourceImage = CIImage(cvPixelBuffer: source)
        var image = sourceImage.oriented(instruction.orientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if image.extent.width != size.width || image.extent.height != size.height, image.extent.width > 0, image.extent.height > 0 {
            image = image.transformed(by: CGAffineTransform(scaleX: size.width / image.extent.width, y: size.height / image.extent.height))
        }

        let time = request.compositionTime.seconds
        if let overlay = overlayImage(instruction.overlay.snapshot, time: time, size: size) {
            image = overlay.composited(over: image)
        }

        CVBufferPropagateAttachments(source, output)
        let destination = CIRenderDestination(pixelBuffer: output)
        destination.colorSpace = sourceImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        destination.alphaMode = .none
        let task = try ciContext.startTask(toRender: image, to: destination)
        try task.waitUntilCompleted()
        request.finish(withComposedVideoFrame: output)
    }

    private func overlayImage(_ snapshot: RenderSnapshot, time: TimeInterval, size: CGSize) -> CIImage? {
        guard let index = snapshot.captions.visibleIndex(at: time, hold: snapshot.hold) else { return nil }
        let caption = snapshot.captions[index]
        let activeIndex = caption.activeWordIndex(at: time)
        let visibleWords = snapshot.style.progressiveReveal ? caption.words.filter { $0.start <= time + 0.0001 }.count : caption.words.count
        var popStep = -1
        if snapshot.style.popActiveWord, let activeIndex {
            let elapsed = time - caption.words[activeIndex].start
            if elapsed >= 0, elapsed < CaptionRenderer.popDuration { popStep = Int(elapsed * 240) }
        }
        let key = OverlayKey(snapshot: snapshot, captionID: caption.id, activeIndex: activeIndex, visibleWords: visibleWords,
                             popStep: popStep, width: size.width, height: size.height)
        if key == cachedKey, let cachedImage { return cachedImage }
        guard let rendered = CaptionRenderer.overlayImage(snapshot, time: time, size: size) else {
            cachedKey = key
            cachedImage = nil
            return nil
        }
        let image = CIImage(cgImage: rendered.image).transformed(by: CGAffineTransform(translationX: rendered.origin.x, y: rendered.origin.y))
        cachedKey = key
        cachedImage = image
        return image
    }
}

nonisolated enum CompositorError: LocalizedError {
    case badInstruction, missingFrame, noOutputBuffer

    var errorDescription: String? {
        switch self {
        case .badInstruction: "The video composition was set up incorrectly."
        case .missingFrame: "A video frame could not be read."
        case .noOutputBuffer: "A frame buffer could not be allocated."
        }
    }
}

/// Builds the video composition that runs the captions over a movie.
nonisolated enum CaptionComposition {
    struct VideoInfo: Sendable {
        var trackID: CMPersistentTrackID
        var naturalSize: CGSize
        var renderSize: CGSize
        var orientation: CGImagePropertyOrientation
        var framesPerSecond: Double
        var duration: CMTime
        var hasAudio: Bool
    }

    static func inspect(_ asset: AVURLAsset) async throws -> VideoInfo {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptionerError.noVideoTrack
        }
        let (naturalSize, transform, frameRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let orientation = orientation(of: transform)
        let rotated = orientation == .left || orientation == .right
        let renderSize = rotated ? CGSize(width: naturalSize.height, height: naturalSize.width) : naturalSize
        let fps = frameRate > 1 ? Double(frameRate) : 30
        return VideoInfo(trackID: track.trackID, naturalSize: naturalSize, renderSize: renderSize, orientation: orientation,
                         framesPerSecond: fps, duration: duration, hasAudio: !audio.isEmpty)
    }

    static func make(info: VideoInfo, overlay: CaptionOverlay) -> AVVideoComposition {
        let instruction = CaptionInstruction(timeRange: CMTimeRange(start: .zero, duration: info.duration), trackID: info.trackID,
                                             orientation: info.orientation, overlay: overlay)
        let configuration = AVVideoComposition.Configuration(
            customVideoCompositorClass: CaptionCompositor.self,
            frameDuration: CMTime(value: 100, timescale: CMTimeScale((info.framesPerSecond * 100).rounded())),
            instructions: [instruction],
            renderSize: info.renderSize,
            sourceTrackIDForFrameTiming: info.trackID)
        return AVVideoComposition(configuration: configuration)
    }

    /// Maps a track's preferred transform to the rotation that shows it upright.
    static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        if t.a == 0, t.b == 1, t.c == -1, t.d == 0 { return .right }
        if t.a == 0, t.b == -1, t.c == 1, t.d == 0 { return .left }
        if t.a == -1, t.d == -1 { return .down }
        return .up
    }
}

nonisolated enum CaptionerError: LocalizedError {
    case noVideoTrack
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "This file has no video track."
        case .exportFailed(let reason): "The video couldn't be exported: \(reason)"
        }
    }
}
