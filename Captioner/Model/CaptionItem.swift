import AVFoundation
import Foundation
import Observation
import os

/// One video in the queue: its media, its captions, and how they look.
@Observable
final class CaptionItem: Identifiable {
    enum Status: Equatable {
        case loading
        case waiting
        case transcribing
        case ready
        case exporting
        case exported
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .loading, .transcribing, .exporting: true
            default: false
            }
        }
    }

    enum Source: Equatable {
        case video
        case subtitles(URL)

        var title: String {
            switch self {
            case .video: "Video"
            case .subtitles(let url): url.lastPathComponent
            }
        }
    }

    let id = UUID()
    let url: URL
    let asset: AVURLAsset
    let overlay: CaptionOverlay

    private(set) var info: CaptionComposition.VideoInfo?
    private(set) var composition: AVVideoComposition?
    private(set) var job: TranscriptionJob?
    private(set) var rawWords: [TranscriptWord] = []

    var status: Status = .loading
    var source: Source = .video
    var localeIdentifier: String
    var captions: [Caption] = [] {
        didSet { publish() }
    }
    var style: CaptionStyle {
        didSet {
            if oldValue.grouping != style.grouping, !hasEdits, !rawWords.isEmpty {
                captions = CaptionBuilder.captions(from: rawWords, grouping: style.grouping)
            }
            publish()
        }
    }
    var placement: PlacementSettings {
        didSet { publish() }
    }
    var textOptions: TextOptions {
        didSet { publish() }
    }
    /// Set once the captions have been edited, so a style change stops regrouping them.
    var hasEdits = false
    var exportProgress: Double = 0
    var exportedURL: URL?

    /// Called whenever the rendered captions change; the preview uses it to repaint a paused frame.
    @ObservationIgnored var onRenderChange: (() -> Void)?

    var name: String { url.deletingPathExtension().lastPathComponent }
    var renderSize: CGSize { info?.renderSize ?? CGSize(width: 16, height: 9) }
    var duration: TimeInterval { info?.duration.seconds ?? 0 }
    var orientation: FrameOrientation { FrameOrientation.of(renderSize) }
    var hasCaptions: Bool { !captions.isEmpty }
    var isTranscribing: Bool { job?.isRunning ?? false }
    var locale: Locale { Locale(identifier: localeIdentifier) }

    init(url: URL, settings: AppSettings) {
        self.url = url
        asset = AVURLAsset(url: url)
        localeIdentifier = settings.localeIdentifier
        style = settings.defaultStyle
        placement = settings.placement
        textOptions = settings.textOptions
        overlay = CaptionOverlay(snapshot: RenderSnapshot(captions: [], style: settings.defaultStyle, placement: settings.placement,
                                                          textOptions: settings.textOptions, hold: settings.captionHold))
    }

    var snapshot: RenderSnapshot {
        RenderSnapshot(captions: captions, style: style, placement: placement, textOptions: textOptions, hold: AppSettings.shared.captionHold)
    }

    private func publish() {
        overlay.snapshot = snapshot
        onRenderChange?()
    }

    func refreshRender() {
        publish()
    }

    /// Reads the video's size, orientation and duration and sets up its composition.
    func load() async {
        let started = Date()
        do {
            let info = try await CaptionComposition.inspect(asset)
            self.info = info
            composition = CaptionComposition.make(info: info, overlay: overlay)
            status = .waiting
            Self.log.notice("Loaded \(self.name, privacy: .public): \(Int(info.renderSize.width))×\(Int(info.renderSize.height)) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
        } catch {
            status = .failed(error.localizedDescription)
            Self.log.error("Failed to load \(self.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    static let log = Logger(subsystem: "fm.beard.Captioner", category: "queue")

    /// A fresh composition over the live overlay; the preview uses one to repaint a paused frame.
    func makeComposition() -> AVVideoComposition? {
        guard let info else { return nil }
        return CaptionComposition.make(info: info, overlay: overlay)
    }

    /// A composition for export, frozen to the captions as they are now.
    func exportComposition() -> AVVideoComposition? {
        guard let info else { return nil }
        return CaptionComposition.make(info: info, overlay: CaptionOverlay(snapshot: snapshot))
    }

    // MARK: - Generating captions

    func startTranscription(completion: @escaping @MainActor () -> Void) {
        job?.cancel()
        let job = TranscriptionJob(locale: locale, maskProfanity: !textOptions.showCurseWords)
        self.job = job
        status = .transcribing
        let started = Date()
        job.start(url: url) { [weak self] words in
            guard let self else { return }
            Self.log.notice("Transcribed \(self.name, privacy: .public): \(words.count) words in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
            rawWords = words
            hasEdits = false
            captions = CaptionBuilder.captions(from: words, grouping: style.grouping)
            status = .ready
            completion()
        }
        Task { [weak self, weak job] in
            // Surface failures and cancellations as the item's status.
            while let job, job.isRunning { try? await Task.sleep(for: .milliseconds(250)) }
            guard let self, let job, self.job === job else { return }
            switch job.phase {
            case .failed(let message):
                status = .failed(message)
                completion()
            case .cancelled:
                if status == .transcribing { status = hasCaptions ? .ready : .waiting }
                completion()
            default:
                break
            }
        }
    }

    func cancelTranscription() {
        job?.cancel()
        job = nil
        if status == .transcribing { status = hasCaptions ? .ready : .waiting }
    }

    func importSubtitles(from subtitleURL: URL) throws {
        let words = try SubtitleImporter.words(from: subtitleURL)
        cancelTranscription()
        source = .subtitles(subtitleURL)
        rawWords = words
        hasEdits = false
        captions = CaptionBuilder.captions(from: words, grouping: style.grouping)
        status = .ready
    }

    func rebuildCaptions() {
        guard !rawWords.isEmpty else { return }
        captions = CaptionBuilder.captions(from: rawWords, grouping: style.grouping)
        hasEdits = false
    }

    // MARK: - Editing

    func updateText(of captionID: UUID, to text: String) {
        guard let index = captions.firstIndex(where: { $0.id == captionID }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != captions[index].text else { return }
        if trimmed.isEmpty {
            captions.remove(at: index)
        } else {
            captions[index] = captions[index].replacingText(trimmed)
        }
        hasEdits = true
    }

    func split(_ captionID: UUID, atWord wordIndex: Int) {
        guard let index = captions.firstIndex(where: { $0.id == captionID }) else { return }
        captions = CaptionBuilder.split(captions, at: index, wordIndex: wordIndex)
        hasEdits = true
    }

    func mergeWithNext(_ captionID: UUID) {
        guard let index = captions.firstIndex(where: { $0.id == captionID }) else { return }
        captions = CaptionBuilder.mergeWithNext(captions, at: index)
        hasEdits = true
    }

    func delete(_ captionID: UUID) {
        captions.removeAll { $0.id == captionID }
        hasEdits = true
    }

    func retime(_ captionID: UUID, start: TimeInterval, end: TimeInterval) {
        guard let index = captions.firstIndex(where: { $0.id == captionID }) else { return }
        captions[index] = captions[index].retimed(start: start, end: end)
        captions = CaptionBuilder.normalized(captions)
        hasEdits = true
    }
}
