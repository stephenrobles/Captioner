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

    var preset: String {
        switch self {
        case .h264: AVAssetExportPresetHighestQuality
        case .hevc: AVAssetExportPresetHEVCHighestQuality
        }
    }
}

/// Writes a movie with the captions burned in, keeping the source resolution and audio.
nonisolated enum VideoExporter {
    static func export(asset: AVURLAsset, composition: AVVideoComposition, to url: URL, codec: ExportCodec,
                       timeRange: CMTimeRange? = nil, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: codec.preset) else {
            throw CaptionerError.exportFailed("this Mac can't encode \(codec == .hevc ? "HEVC" : "H.264") at this size")
        }
        session.videoComposition = composition
        session.shouldOptimizeForNetworkUse = true
        if let timeRange { session.timeRange = timeRange }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let monitor = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: url, as: .mp4)
        progress(1)
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
