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
    var watermark: WatermarkSettings {
        didSet { publish() }
    }
    /// Whether, and how many, speakers to look for. Turning it on identifies them; off clears them.
    var speakerMode: SpeakerMode {
        didSet { if oldValue != speakerMode { speakerModeChanged() } }
    }
    private(set) var isDetectingSpeakers = false
    /// What detection is doing right now ("Listening for voices…").
    private(set) var speakerStatus = ""
    private(set) var speakerProgress: Double = 0
    /// How many voices the last detection found.
    private(set) var speakerCount = 0
    var speakerError: String?
    @ObservationIgnored private var speakerTask: Task<Void, Never>?
    /// Set once the captions have been edited, so a style change stops regrouping them.
    var hasEdits = false
    /// Arrived through a watched folder: handled without the Finder popping up.
    var isFromWatchedFolder = false
    /// Present while the captions are a translation of the original speech.
    var translation: TranslationInfo?
    var isTranslating = false
    var translationError: String?
    var exportProgress: Double = 0
    var exportedURL: URL?
    /// Whether `exportedURL` is a captions-only movie (transparent, no audio) rather than the captioned video.
    var exportedCaptionsOnly = false

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
        watermark = settings.watermark
        speakerMode = settings.speakerMode
        overlay = CaptionOverlay(snapshot: RenderSnapshot(captions: [], style: settings.defaultStyle, placement: settings.placement,
                                                          textOptions: settings.textOptions, hold: settings.captionHold, watermark: settings.watermark))
    }

    var snapshot: RenderSnapshot {
        RenderSnapshot(captions: captions, style: style, placement: placement, textOptions: textOptions, hold: AppSettings.shared.captionHold,
                       watermark: watermark)
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

    /// A composition for export, frozen to the captions as they are now. `captionsOnly` draws
    /// them over a transparent frame instead of the video.
    func exportComposition(captionsOnly: Bool = false) -> AVVideoComposition? {
        guard let info else { return nil }
        return CaptionComposition.make(info: info, overlay: CaptionOverlay(snapshot: snapshot), captionsOnly: captionsOnly)
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
            translation = nil
            translationError = nil
            captions = CaptionBuilder.captions(from: words, grouping: style.grouping)
            status = .ready
            speakerCount = 0
            if speakerMode.isOn { detectSpeakers() }
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

    // MARK: - Speakers

    /// Listens to the video again and labels every word with a voice, then colors the captions.
    /// Unedited captions are regrouped so a line never spans two speakers; edited ones keep
    /// their grouping and take the voice that covers most of each line.
    func detectSpeakers() {
        speakerTask?.cancel()
        guard speakerMode.isOn, !rawWords.isEmpty else { return }
        let mode = speakerMode
        let words = rawWords
        let url = self.url
        isDetectingSpeakers = true
        speakerProgress = 0
        speakerStatus = SpeakerDetector.needsModelDownload ? "Downloading the speaker model…" : "Reading audio…"
        speakerError = nil
        let started = Date()
        speakerTask = Task { [weak self] in
            let outcome: Result<[Int?], Error>
            do {
                outcome = .success(try await SpeakerDetector.detect(url: url, words: words, mode: mode) { phase in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        switch phase {
                        case .downloading(let fraction):
                            speakerStatus = "Downloading the speaker model…"
                            speakerProgress = fraction
                        case .preparing:
                            speakerStatus = "Preparing the speaker model…"
                            speakerProgress = 0
                        case .listening(let fraction):
                            speakerStatus = "Listening for voices…"
                            speakerProgress = fraction
                        }
                    }
                })
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            isDetectingSpeakers = false
            switch outcome {
            case .success(let labels):
                guard rawWords == words else { return }
                var labelled = words
                for index in labelled.indices { labelled[index].speaker = labels[index] }
                applySpeakers(words: labelled)
                Self.log.notice("Identified \(self.speakerCount) speakers in \(self.name, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
            case .failure(let error):
                speakerError = error.localizedDescription
                Self.log.error("Speaker detection failed for \(self.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func applySpeakers(words labelled: [TranscriptWord]) {
        rawWords = labelled
        if var translation {
            // The originals are kept for "Original": give them the same voices by time.
            translation.originalWords = translation.originalWords.map { word in
                var updated = word
                updated.speaker = CaptionBuilder.dominantSpeaker(of: labelled.filter { $0.end > word.start && $0.start < word.end })
                return updated
            }
            translation.originalCaptions = translation.originalCaptions.map { caption in
                var updated = caption
                updated.speaker = Self.speaker(covering: caption, in: labelled)
                return updated
            }
            self.translation = translation
        }
        speakerCount = Set(labelled.compactMap(\.speaker)).count
        if hasEdits {
            captions = captions.map { caption in
                var updated = caption
                updated.speaker = Self.speaker(covering: caption, in: labelled)
                updated.words = updated.words.map { var word = $0; word.speaker = updated.speaker; return word }
                return updated
            }
        } else {
            captions = CaptionBuilder.captions(from: labelled, grouping: style.grouping)
        }
    }

    /// The voice that speaks for most of `caption`'s span.
    private static func speaker(covering caption: Caption, in words: [TranscriptWord]) -> Int? {
        let overlapping = words.filter { $0.end > caption.start && $0.start < caption.end }
        return CaptionBuilder.dominantSpeaker(of: overlapping)
    }

    private func speakerModeChanged() {
        speakerTask?.cancel()
        isDetectingSpeakers = false
        speakerError = nil
        if speakerMode.isOn {
            detectSpeakers()
        } else {
            speakerCount = 0
            rawWords = rawWords.map { var word = $0; word.speaker = nil; return word }
            captions = captions.map { caption in
                var cleared = caption
                cleared.speaker = nil
                cleared.words = cleared.words.map { var word = $0; word.speaker = nil; return word }
                return cleared
            }
        }
    }

    /// Changes one caption's voice by hand.
    func setSpeaker(_ speaker: Int?, of captionID: UUID) {
        guard let index = captions.firstIndex(where: { $0.id == captionID }), captions[index].speaker != speaker else { return }
        captions[index].speaker = speaker
        captions[index].words = captions[index].words.map { var word = $0; word.speaker = speaker; return word }
        hasEdits = true
    }

    func importSubtitles(from subtitleURL: URL) throws {
        let words = try SubtitleImporter.words(from: subtitleURL)
        cancelTranscription()
        source = .subtitles(subtitleURL)
        rawWords = words
        hasEdits = false
        translation = nil
        translationError = nil
        captions = CaptionBuilder.captions(from: words, grouping: style.grouping)
        status = .ready
        speakerCount = 0
        if speakerMode.isOn { detectSpeakers() }
    }

    func rebuildCaptions() {
        guard !rawWords.isEmpty else { return }
        captions = CaptionBuilder.captions(from: rawWords, grouping: style.grouping)
        hasEdits = false
    }

    // MARK: - Translation

    /// The captions a translation starts from: always the original speech, never a translation.
    var captionsForTranslation: [Caption] {
        translation?.originalCaptions ?? captions
    }

    /// Replaces the captions with translated words, keeping the originals to come back to.
    func applyTranslation(words: [TranscriptWord], targetIdentifier: String) {
        if translation == nil {
            translation = TranslationInfo(targetIdentifier: targetIdentifier, originalWords: rawWords, originalCaptions: captions)
        } else {
            translation?.targetIdentifier = targetIdentifier
        }
        rawWords = words
        captions = CaptionBuilder.captions(from: words, grouping: style.grouping)
        hasEdits = false
        translationError = nil
    }

    func revertTranslation() {
        guard let translation else { return }
        rawWords = translation.originalWords
        captions = translation.originalCaptions
        self.translation = nil
        translationError = nil
        hasEdits = false
    }

    // MARK: - Editing

    func updateText(of captionID: UUID, to text: String) {
        guard let index = captions.firstIndex(where: { $0.id == captionID }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != captions[index].text else { return }
        // An emptied line becomes a blank caption: nothing shows while it is on screen.
        captions[index] = captions[index].replacingText(trimmed)
        hasEdits = true
    }

    /// Adds a blank caption after `captionID`, filling the gap up to the next caption (or one
    /// second when it is the last).
    func insertBlank(after captionID: UUID) {
        guard let index = captions.firstIndex(where: { $0.id == captionID }) else { return }
        let start = captions[index].end
        let end = index + 1 < captions.count ? max(captions[index + 1].start, start + 0.05) : start + 1
        captions.insert(.blank(start: start, end: end), at: index + 1)
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
