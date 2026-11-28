import Foundation

/// Resolve ASR differences inside a phrase heard on both tracks. Exact text alone is
/// insufficient to discard an intervening word: the acoustic profile must also show playback.
enum PlaybackTranscript {
    private struct Token {
        let text: String
        let word: Int
        let range: TimeRange
    }

    private static func tokens(_ words: [TimedWord]) -> [Token] {
        words.enumerated().flatMap { index, word in
            word.text.lowercased().split { $0.isWhitespace || $0 == "-" || $0 == "‐" || $0 == "‑" }
                .compactMap { part in
                    let key = part.filter { $0.isLetter || $0.isNumber }
                    return key.isEmpty ? nil : Token(text: key, word: index, range: word.range)
                }
        }
    }

    static func echoes(mic: [TimedWord], remote: [TimedWord], profile: EchoProfile) -> Set<TimedWord> {
        guard !mic.isEmpty, !remote.isEmpty else { return [] }
        let capture = tokens(mic)
        let parts = Dictionary(grouping: capture, by: \.word).mapValues(\.count)
        let reference = tokens(remote)
        var matches: [(mic: Token, remote: Int)] = []
        var dropped: Set<TimedWord> = []
        func finish() {
            defer { matches.removeAll(keepingCapacity: true) }
            guard Set(matches.map { $0.mic.word }).count >= Alignment.repeatRun else { return }
            let evidence = matches.map(\.mic).filter { profile.isEcho($0.range) }
            guard !evidence.isEmpty else { return }
            let matchedParts = Dictionary(grouping: matches, by: { $0.mic.word })
            var supported: Set<Int> = []
            var next = 0
            // Require playback evidence locally, even for a long uninterrupted stream of matching text.
            let reach = 3 * Alignment.repeatWindow
            for match in matches {
                let token = match.mic
                while next < evidence.count && evidence[next].range.end < token.range.start - reach { next += 1 }
                if next < evidence.count, evidence[next].range.start <= token.range.end + reach,
                   matchedParts[token.word]?.count == parts[token.word] {
                    dropped.insert(mic[token.word])
                    supported.insert(token.word)
                }
            }
            for (left, right) in zip(matches, matches.dropFirst()) {
                let gap = (left.mic.word + 1)..<max(left.mic.word + 1, right.mic.word)
                guard !gap.isEmpty, right.remote > left.remote + 1,
                      supported.contains(left.mic.word), supported.contains(right.mic.word) else { continue }
                // A substitution occupies a gap on both tracks. Keep an independent
                // interjection, including a different script spoken over the playback.
                let missed = reference[(left.remote + 1)..<right.remote]
                for i in gap {
                    let letters = mic[i].text.unicodeScalars.filter(CharacterSet.letters.contains)
                    guard !letters.isEmpty else { continue }
                    let latin = letters.allSatisfy { $0.isASCII }
                    let range = mic[i].range
                    if latin && profile.hasActivePlayback(during: range) && missed.contains(where: {
                        $0.text.allSatisfy { $0.isASCII && $0.isLetter } &&
                            abs($0.range.start - range.start) <= Alignment.repeatWindow
                    }) { dropped.insert(mic[i]) }
                }
            }
        }
        var start = 0
        var preceding: Token?
        for token in capture {
            if let preceding, token.range.start - preceding.range.end > EchoProfile.runGap { finish() }
            preceding = token
            let time = token.range.start
            while start < reference.count && reference[start].range.start < time - Alignment.repeatWindow { start += 1 }
            if let last = matches.last, time - last.mic.range.end > 2 * Alignment.repeatWindow { finish() }
            var index = max(start, matches.last.map { $0.remote + 1 } ?? start)
            while index < reference.count && reference[index].range.start <= time + Alignment.repeatWindow {
                if reference[index].text == token.text {
                    if let last = matches.last, reference[index].range.start - reference[last.remote].range.end > 2 * Alignment.repeatWindow {
                        finish()
                    }
                    matches.append((token, index))
                    break
                }
                index += 1
            }
        }
        finish()
        return dropped
    }
}
