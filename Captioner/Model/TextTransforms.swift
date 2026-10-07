import Foundation

/// The transcription controls. They are applied when captions are drawn, so toggling them
/// never touches the words you edited.
nonisolated struct TextOptions: Codable, Hashable, Sendable {
    var showPunctuation = true
    var titleCase = false
    var showCurseWords = true

    static let `default` = TextOptions()
}

nonisolated enum TextTransforms {
    static func apply(_ options: TextOptions, to text: String) -> String {
        var result = text
        if !options.showPunctuation { result = strippingPunctuation(result) }
        if !options.showCurseWords { result = maskingProfanity(result) }
        if options.titleCase { result = titleCased(result) }
        return result
    }

    /// Removes punctuation but keeps apostrophes and hyphens inside words ("don't", "on-device").
    static func strippingPunctuation(_ text: String) -> String {
        var output = ""
        let characters = Array(text)
        for (i, character) in characters.enumerated() {
            if character.isPunctuation || character.isSymbol {
                let inner = i > 0 && i + 1 < characters.count && characters[i - 1].isLetter && characters[i + 1].isLetter
                if inner, "'’-".contains(character) {
                    output.append(character)
                }
                continue
            }
            output.append(character)
        }
        return output
    }

    static func titleCased(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { piece -> String in
            guard let first = piece.firstIndex(where: { $0.isLetter }) else { return String(piece) }
            var word = String(piece)
            let offset = piece.distance(from: piece.startIndex, to: first)
            let index = word.index(word.startIndex, offsetBy: offset)
            word.replaceSubrange(index...index, with: String(word[index]).uppercased())
            return word
        }.joined(separator: " ")
    }

    /// Replaces common English profanity with its first letter and asterisks ("f***").
    static func maskingProfanity(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { piece -> String in
            let letters = piece.filter { $0.isLetter }.lowercased()
            guard !letters.isEmpty, isProfane(letters) else { return String(piece) }
            var masked = ""
            var seenLetter = false
            for character in piece {
                if character.isLetter {
                    masked.append(seenLetter ? "*" : character)
                    seenLetter = true
                } else {
                    masked.append(character)
                }
            }
            return masked
        }.joined(separator: " ")
    }

    private static func isProfane(_ word: String) -> Bool {
        if profanity.contains(word) { return true }
        return profanityStems.contains { word.hasPrefix($0) && word.count <= $0.count + 4 }
    }

    private static let profanity: Set<String> = [
        "ass", "arse", "bastard", "bitch", "bollocks", "bullshit", "cock", "crap", "cunt", "damn", "dick",
        "dickhead", "douche", "douchebag", "fuck", "goddamn", "hell", "jackass", "motherfucker", "piss",
        "prick", "pussy", "shit", "slut", "twat", "wanker", "whore", "asshole",
    ]
    private static let profanityStems: [String] = ["fuck", "shit", "bitch", "cunt", "damn", "piss", "dick", "ass", "bullshit", "motherfuck"]
}
