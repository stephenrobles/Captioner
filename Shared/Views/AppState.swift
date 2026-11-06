import SwiftUI
import Translation

/// Window-level state the menus and the main view share.
@Observable
final class AppState {
    let player = PlayerController()
    var showInspector = true
    var showGallery = false
    /// The caption picked in the timeline; the list highlights it and scrolls to it.
    var selectedCaptionID: UUID?

    /// A translation waiting for the view's translation session.
    struct TranslationRequest {
        let itemID: UUID
        let target: Locale.Language
        var configuration: TranslationSession.Configuration
    }

    var translationRequest: TranslationRequest?

    /// Asks the main view's translation session to translate `item`. The session is only
    /// reachable through SwiftUI, which also shows the language download sheet when needed.
    func translate(_ item: CaptionItem, to target: Locale.Language) {
        guard item.hasCaptions else { return }
        var configuration = TranslationSession.Configuration(source: item.locale.language, target: target)
        configuration.invalidate()
        item.isTranslating = true
        item.translationError = nil
        translationRequest = TranslationRequest(itemID: item.id, target: target, configuration: configuration)
    }

    /// Runs the pending request with the session SwiftUI handed us.
    func performTranslation(with session: TranslationSession, queue: CaptionQueue) async {
        guard let request = translationRequest else { return }
        guard let item = queue.items.first(where: { $0.id == request.itemID }) else {
            translationRequest = nil
            return
        }
        defer {
            item.isTranslating = false
            translationRequest = nil
        }
        let captions = item.captionsForTranslation
        let groups = CaptionTranslator.sentenceGroups(captions, pauseBreak: max(1, item.style.grouping.pauseBreak))
        let requests = groups.enumerated().compactMap { index, group -> TranslationSession.Request? in
            let text = CaptionTranslator.sentenceText(captions, group: group)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
        }
        do {
            let responses = try await session.translations(from: requests)
            var translated: [String: String] = [:]
            for response in responses {
                if let id = response.clientIdentifier { translated[id] = response.targetText }
            }
            var words: [TranscriptWord] = []
            for (index, group) in groups.enumerated() {
                let text = translated[String(index)] ?? CaptionTranslator.sentenceText(captions, group: group)
                words += CaptionTranslator.words(for: captions, group: group, translation: text)
            }
            guard !words.isEmpty else { throw CaptionerError.exportFailed("the translation came back empty") }
            item.applyTranslation(words: words, targetIdentifier: request.target.minimalIdentifier)
        } catch is CancellationError {
            // The download sheet was dismissed or the session went away; leave the captions as they were.
        } catch {
            item.translationError = error.localizedDescription
        }
    }
}
