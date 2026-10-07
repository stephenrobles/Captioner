import Foundation

/// How words are grouped into on-screen captions. Line limits come from the style
/// (a monoline style wants a handful of words; a multiline one can hold more).
nonisolated struct CaptionGrouping: Codable, Hashable, Sendable {
    var maxWordsPerLine: Int = 5
    var maxLines: Int = 1
    var maxCharactersPerLine: Int = 24
    var maxDuration: TimeInterval = 4
    var pauseBreak: TimeInterval = 0.8

    var maxWords: Int { max(1, maxWordsPerLine * maxLines) }
}

/// Groups recognized words into captions: first into phrases (at pauses and sentence ends),
/// then each phrase into evenly sized chunks that fit the style, preferring to cut at commas.
nonisolated enum CaptionBuilder {
    static func captions(from words: [TranscriptWord], grouping: CaptionGrouping) -> [Caption] {
        var captions: [Caption] = []
        for phrase in phrases(words, pauseBreak: grouping.pauseBreak) {
            for chunk in chunks(phrase, grouping: grouping) {
                captions.append(Caption(words: chunk))
            }
        }
        return normalized(captions)
    }

    /// Splits at pauses and after sentence-ending punctuation.
    static func phrases(_ words: [TranscriptWord], pauseBreak: TimeInterval) -> [[TranscriptWord]] {
        var phrases: [[TranscriptWord]] = []
        var current: [TranscriptWord] = []
        for word in words where !word.text.isEmpty {
            if let last = current.last {
                if word.start - last.end >= pauseBreak || endsSentence(last.text) {
                    phrases.append(current)
                    current = []
                }
            }
            current.append(word)
        }
        if !current.isEmpty { phrases.append(current) }
        return phrases
    }

    /// Cuts one phrase into the fewest chunks that fit, sized as evenly as possible.
    static func chunks(_ phrase: [TranscriptWord], grouping: CaptionGrouping) -> [[TranscriptWord]] {
        guard !phrase.isEmpty else { return [] }
        if fits(phrase, grouping: grouping) { return [phrase] }
        var count = max(2, Int((Double(phrase.count) / Double(grouping.maxWords)).rounded(.up)))
        while count < phrase.count {
            let pieces = split(phrase, into: count)
            if pieces.allSatisfy({ fits($0, grouping: grouping) }) { return pieces }
            count += 1
        }
        return phrase.map { [$0] }
    }

    /// Divides `phrase` into `count` runs of near-equal length, nudging each boundary onto a
    /// clause end (comma, semicolon…) when one is a word away.
    private static func split(_ phrase: [TranscriptWord], into count: Int) -> [[TranscriptWord]] {
        var boundaries: [Int] = []
        var previous = 0
        for i in 1..<count {
            let ideal = Int((Double(i) * Double(phrase.count) / Double(count)).rounded())
            var chosen = ideal
            for candidate in [ideal, ideal - 1, ideal + 1] where candidate > previous && candidate < phrase.count {
                if endsClause(phrase[candidate - 1].text) {
                    chosen = candidate
                    break
                }
            }
            chosen = max(previous + 1, min(chosen, phrase.count - (count - i)))
            boundaries.append(chosen)
            previous = chosen
        }
        var pieces: [[TranscriptWord]] = []
        var start = 0
        for boundary in boundaries + [phrase.count] {
            pieces.append(Array(phrase[start..<boundary]))
            start = boundary
        }
        return pieces.filter { !$0.isEmpty }
    }

    /// Whether `group` fits the style: word and character limits per line, lines, and duration.
    static func fits(_ group: [TranscriptWord], grouping: CaptionGrouping) -> Bool {
        guard let first = group.first, let last = group.last else { return true }
        if group.count > grouping.maxWords { return false }
        if last.end - first.start > grouping.maxDuration, group.count > 1 { return false }
        let lineLimit = max(grouping.maxCharactersPerLine, 6)
        let wordsPerLine = max(grouping.maxWordsPerLine, 1)
        var lines = 1
        var lineLength = 0
        var lineWords = 0
        for word in group {
            let length = word.text.count
            if lineWords == 0 {
                lineLength = length
                lineWords = 1
            } else if lineWords < wordsPerLine, lineLength + 1 + length <= lineLimit {
                lineLength += 1 + length
                lineWords += 1
            } else {
                lines += 1
                lineLength = length
                lineWords = 1
            }
        }
        return lines <= max(grouping.maxLines, 1)
    }

    /// Keeps captions in order and non-overlapping, and gives very short words a readable minimum.
    static func normalized(_ input: [Caption]) -> [Caption] {
        var captions = input.filter { !$0.words.isEmpty }.sorted { $0.start < $1.start }
        for i in captions.indices {
            var words = captions[i].words
            for j in words.indices {
                if words[j].end < words[j].start + 0.05 { words[j].end = words[j].start + 0.05 }
                if j + 1 < words.count, words[j].end > words[j + 1].start { words[j].end = max(words[j + 1].start, words[j].start + 0.05) }
            }
            captions[i].words = words
        }
        return captions
    }

    static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last(where: { !$0.isPunctuation || ".?!…".contains($0) }) else { return false }
        return ".?!…".contains(last)
    }

    static func endsClause(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ",;:—–".contains(last)
    }

    // MARK: - Editing

    /// Splits caption `index` so that words from `wordIndex` on start a new caption.
    static func split(_ captions: [Caption], at index: Int, wordIndex: Int) -> [Caption] {
        guard captions.indices.contains(index) else { return captions }
        let caption = captions[index]
        guard wordIndex > 0, wordIndex < caption.words.count else { return captions }
        var result = captions
        result[index] = Caption(id: caption.id, words: Array(caption.words[..<wordIndex]))
        result.insert(Caption(words: Array(caption.words[wordIndex...])), at: index + 1)
        return result
    }

    /// Merges caption `index` with the one after it.
    static func mergeWithNext(_ captions: [Caption], at index: Int) -> [Caption] {
        guard captions.indices.contains(index), index + 1 < captions.count else { return captions }
        var result = captions
        let merged = Caption(id: captions[index].id, words: captions[index].words + captions[index + 1].words)
        result[index] = merged
        result.remove(at: index + 1)
        return result
    }
}
