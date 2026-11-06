import Foundation

// Usage: wordsrt <media> <out.srt> — transcribes on device and writes one cue per word.
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])
nonisolated func stamp(_ t: TimeInterval) -> String {
    let ms = Int((t * 1000).rounded()); return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
}
Task {
    do {
        var words: [TranscriptWord] = []
        for try await event in TranscriptionEngine.transcribe(url: url, locale: Locale(identifier: "en-US"), maskProfanity: false) {
            if case .words(let new) = event { words += new }
        }
        var srt = ""; var n = 0
        for w in words where !w.text.isEmpty {
            n += 1; srt += "\(n)\n\(stamp(w.start)) --> \(stamp(max(w.end, w.start + 0.05)))\n\(w.text)\n\n"
        }
        try srt.write(to: out, atomically: true, encoding: .utf8)
        print("\(out.lastPathComponent): \(n) words")
    } catch { print("error: \(error)") }
    exit(0)
}
RunLoop.main.run()
