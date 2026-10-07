import Foundation

/// One recognized word with the time it was spoken.
nonisolated struct TranscriptWord: Codable, Hashable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval

    var duration: TimeInterval { max(0, end - start) }
}

/// One caption: a short group of words shown together on screen. The active word is the one
/// being spoken, so each word keeps its own timing.
nonisolated struct Caption: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var words: [TranscriptWord]

    init(id: UUID = UUID(), words: [TranscriptWord]) {
        self.id = id
        self.words = words
    }

    var start: TimeInterval { words.first?.start ?? 0 }
    var end: TimeInterval { words.last?.end ?? start }
    var duration: TimeInterval { max(0, end - start) }
    var text: String { words.map(\.text).joined(separator: " ") }

    /// The word being spoken at `time`: the last one that has started. Stays on the last word
    /// of the caption once it has been said, so the highlight never blinks off between words.
    func activeWordIndex(at time: TimeInterval) -> Int? {
        guard !words.isEmpty else { return nil }
        var index: Int?
        for (i, word) in words.enumerated() where word.start <= time { index = i }
        return index
    }

    /// Replaces the caption's text, keeping its time span. The new words share the span in
    /// proportion to their length so highlighting still moves at roughly the spoken pace.
    func replacingText(_ text: String) -> Caption {
        let pieces = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        guard !pieces.isEmpty else { return Caption(id: id, words: []) }
        let span = max(duration, 0.2)
        let totalLength = Double(pieces.reduce(0) { $0 + $1.count })
        var cursor = start
        var newWords: [TranscriptWord] = []
        for piece in pieces {
            let share = totalLength > 0 ? Double(piece.count) / totalLength : 1 / Double(pieces.count)
            let wordEnd = cursor + span * share
            newWords.append(TranscriptWord(text: piece, start: cursor, end: wordEnd))
            cursor = wordEnd
        }
        newWords[newWords.count - 1].end = end
        return Caption(id: id, words: newWords)
    }

    func retimed(start newStart: TimeInterval, end newEnd: TimeInterval) -> Caption {
        guard !words.isEmpty, newEnd > newStart else { return self }
        let oldSpan = max(duration, 0.001)
        let scale = (newEnd - newStart) / oldSpan
        let moved = words.map { word in
            TranscriptWord(text: word.text,
                           start: newStart + (word.start - start) * scale,
                           end: newStart + (word.end - start) * scale)
        }
        return Caption(id: id, words: moved)
    }
}

nonisolated extension Array where Element == Caption {
    /// Index of the caption that started most recently before `time`.
    func index(at time: TimeInterval) -> Int? {
        guard !isEmpty else { return nil }
        var low = 0, high = count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if self[mid].start <= time { low = mid } else { high = mid - 1 }
        }
        return self[low].start <= time ? low : nil
    }

    /// When caption `index` leaves the screen: it holds until the next caption begins, up to
    /// `hold` seconds after its last word, so captions do not flicker off between phrases.
    func displayEnd(of index: Int, hold: TimeInterval) -> TimeInterval {
        let caption = self[index]
        let natural = caption.end + hold
        if index + 1 < count { return Swift.min(natural, self[index + 1].start) }
        return natural
    }

    /// The caption visible at `time`, if any.
    func visibleIndex(at time: TimeInterval, hold: TimeInterval) -> Int? {
        guard let index = index(at: time) else { return nil }
        return time < displayEnd(of: index, hold: hold) ? index : nil
    }
}
