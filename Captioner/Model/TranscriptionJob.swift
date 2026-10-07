import Foundation
import Observation

/// Drives one transcription run and exposes its progress to the UI.
@Observable
final class TranscriptionJob {
    enum Phase: Equatable {
        case preparing
        case downloading
        case transcribing
        case finished
        case failed(String)
        case cancelled
    }

    private(set) var phase: Phase = .preparing
    private(set) var status = "Starting…"
    private(set) var progress: Double = 0
    private(set) var downloadProgress: Double = 0
    private(set) var words: [TranscriptWord] = []
    private(set) var volatileText = ""
    let locale: Locale
    let maskProfanity: Bool

    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool {
        switch phase {
        case .preparing, .downloading, .transcribing: true
        default: false
        }
    }

    /// The last few finalized words plus the engine's current guess, for the live view.
    var liveText: String {
        let tail = words.suffix(12).map(\.text).joined(separator: " ")
        return volatileText.isEmpty ? tail : tail + " " + volatileText
    }

    init(locale: Locale, maskProfanity: Bool) {
        self.locale = locale
        self.maskProfanity = maskProfanity
    }

    func start(url: URL, completion: @escaping @MainActor ([TranscriptWord]) -> Void) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in TranscriptionEngine.transcribe(url: url, locale: locale, maskProfanity: maskProfanity) {
                    switch event {
                    case .status(let text):
                        status = text
                        if phase == .downloading { phase = .preparing }
                    case .downloading(let fraction):
                        phase = .downloading
                        downloadProgress = fraction
                    case .progress(let fraction):
                        phase = .transcribing
                        progress = max(progress, fraction)
                    case .volatile(let text):
                        phase = .transcribing
                        volatileText = text
                    case .words(let new):
                        phase = .transcribing
                        words.append(contentsOf: new)
                    }
                }
                guard !Task.isCancelled else {
                    phase = .cancelled
                    return
                }
                phase = .finished
                progress = 1
                completion(words)
            } catch is CancellationError {
                phase = .cancelled
            } catch {
                phase = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        phase = .cancelled
    }
}
