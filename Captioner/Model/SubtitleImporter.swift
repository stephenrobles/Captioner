import Foundation
import UniformTypeIdentifiers

/// Reads SRT and WebVTT files into timed words. Subtitle cues only time whole lines, so each
/// cue's span is shared out across its words by length.
nonisolated enum SubtitleImporter {
    static let types: [UTType] = [UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "vtt") ?? .plainText, .plainText]

    static func words(from url: URL) throws -> [TranscriptWord] {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        let words = words(from: text)
        guard !words.isEmpty else { throw ImportError.noCues }
        return words
    }

    static func words(from text: String) -> [TranscriptWord] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var words: [TranscriptWord] = []
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            guard let (start, end) = parseTiming(lines[timingIndex]) else { continue }
            let body = lines[(timingIndex + 1)...].joined(separator: " ")
            let cleaned = stripTags(body)
            let pieces = cleaned.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !pieces.isEmpty else { continue }
            let span = max(end - start, 0.2)
            let total = Double(pieces.reduce(0) { $0 + $1.count })
            var cursor = start
            for (i, piece) in pieces.enumerated() {
                let share = total > 0 ? Double(piece.count) / total : 1 / Double(pieces.count)
                let wordEnd = i == pieces.count - 1 ? start + span : cursor + span * share
                words.append(TranscriptWord(text: piece, start: cursor, end: wordEnd))
                cursor = wordEnd
            }
        }
        return words.sorted { $0.start < $1.start }
    }

    private static func parseTiming(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let startText = parts[0].trimmingCharacters(in: .whitespaces)
        let endText = parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
        guard let start = TimeFormat.parse(startText), let end = TimeFormat.parse(endText), end > start else { return nil }
        return (start, end)
    }

    private static func stripTags(_ text: String) -> String {
        var result = ""
        var inTag = false
        for character in text {
            if character == "<" { inTag = true; continue }
            if character == ">" { inTag = false; continue }
            if !inTag { result.append(character) }
        }
        return result.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }

    enum ImportError: LocalizedError {
        case noCues

        var errorDescription: String? { "No subtitle cues were found in this file." }
    }
}
