import Foundation

/// SubRip (.srt) text for the raw or cleaned transcript.
public enum Subtitles {
    /// Longest text of one cue; a longer line is cut at punctuation, or at this length when it has none.
    static let maxCueCharacters = 36

    struct Cue: Equatable {
        let range: TimeRange
        let text: String
    }

    /// nil for the views that are not a timed transcript, or when the cleaned one is not generated.
    public static func srt(_ meeting: Meeting, view: TranscriptView, name: (SpeakerID) -> String) -> String? {
        let lines: [(TimeRange, SpeakerID, String)]
        switch view {
        case .raw:
            lines = meeting.utterances.map { ($0.range, $0.speaker, $0.text) }
        case .cleaned:
            guard let cleaned = meeting.outputs.cleaned else { return nil }
            lines = cleaned.paragraphs.compactMap { paragraph in
                meeting.timeRange(of: paragraph.sources).map {
                    ($0, paragraph.speaker, SpeakerMention.substitute(in: paragraph.text, name: name))
                }
            }
        case .perPerson, .summary:
            return nil
        }
        let cues = lines.flatMap { range, speaker, text in
            Self.cues(text, in: range).map { Cue(range: $0.range, text: "\(name(speaker)): \($0.text)") }
        }
        return cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.range.start)) --> \(timestamp(cue.range.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    /// Cuts a line into cue-sized pieces and gives each a share of the time in proportion to its length.
    static func cues(_ text: String, in range: TimeRange) -> [Cue] {
        let pieces = pieces(text)
        let total = pieces.reduce(0) { $0 + $1.count }
        guard total > 0 else { return [] }
        var spoken = 0
        return pieces.map { piece in
            let start = range.start + range.duration * Double(spoken) / Double(total)
            spoken += piece.count
            return Cue(range: TimeRange(start: start, end: range.start + range.duration * Double(spoken) / Double(total)), text: piece)
        }
    }

    static func pieces(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
            current = ""
        }
        for sentence in sentences(text) {
            if !current.isEmpty, current.count + sentence.count > maxCueCharacters { flush() }
            var rest = Substring(sentence)
            // A sentence with no punctuation to cut at is cut at a space, or failing that mid-run.
            while rest.count > maxCueCharacters {
                let window = rest.prefix(maxCueCharacters)
                let cut = window.lastIndex(of: " ").flatMap { $0 > window.startIndex ? $0 : nil } ?? window.endIndex
                current = String(rest[..<cut])
                flush()
                rest = rest[cut...]
            }
            current += rest
        }
        flush()
        return pieces
    }

    /// Runs of text each ending with the punctuation that closed them.
    private static func sentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            if character.isNewline {
                if !current.isEmpty { sentences.append(current) }
                current = ""
                continue
            }
            current.append(character)
            if "。！？!?；;，,、".contains(character) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty { sentences.append(current) }
        return sentences
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
