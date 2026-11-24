import Foundation

/// What Captioner does with a video that lands in a watched folder: add it to the queue with the
/// default style, wait for its captions, and export it like a dropped video. Returns the
/// exported file, for the notification.
@MainActor
enum WatchProcessor {
    static func accepts(_ url: URL) -> Bool {
        CaptionQueue.isVideo(url) && !isExport(url)
    }

    /// Captioner's own outputs ("Talk Captioned.mp4", "Talk Captioned 2.mp4", and the captions-only
    /// "Talk Captions.mov") land in the same folder and must not be captioned again.
    nonisolated static func isExport(_ url: URL) -> Bool {
        let base = url.deletingPathExtension().lastPathComponent
        return ends(base, with: " Captioned") || (url.pathExtension.lowercased() == "mov" && ends(base, with: " Captions"))
    }

    /// Whether `base` ends in `suffix`, or in `suffix` and the number given to a second copy.
    private nonisolated static func ends(_ base: String, with suffix: String) -> Bool {
        guard let range = base.range(of: suffix, options: .backwards) else { return false }
        let tail = base[range.upperBound...]
        return tail.isEmpty || (tail.hasPrefix(" ") && tail.dropFirst().allSatisfy(\.isNumber))
    }

    static func caption(_ url: URL) async throws -> URL? {
        let queue = CaptionQueue.shared
        guard let item = queue.addFromWatchedFolder(url) else { throw WatchError.notAVideo }
        try await queue.waitForCaptions(of: item)
        return try await queue.exportAndWait(item)
    }
}
