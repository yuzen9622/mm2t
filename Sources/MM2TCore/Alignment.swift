import Foundation

/// Merges STT word timestamps with diarization into utterances.
public enum Alignment {
    /// A pause longer than this starts a new utterance even when the speaker does not change.
    static let maxPause: TimeInterval = 1.5

    /// Mic words are always `.me`. Each remote word goes to the segment it overlaps most,
    /// or the nearest segment when it falls in a gap.
    public static func utterances(
        me: [TimedWord],
        remote: [TimedWord],
        segments: [SpeakerSegment],
        overlaps: [TimeRange]
    ) -> [Utterance] {
        let mine = group(me.map { (SpeakerID.me, $0) })
        let theirs = group(remote.compactMap { word in
            speaker(for: word.range, in: segments).map { ($0, word) }
        })
        let drafts = (mine + theirs).sorted { ($0.range.start, $0.speaker.rawValue) < ($1.range.start, $1.speaker.rawValue) }
        return drafts.enumerated().map { index, draft in
            Utterance(
                id: UtteranceID("u\(index + 1)"),
                speaker: draft.speaker,
                range: draft.range,
                isOverlapping: draft.speaker != .me && overlaps.contains { $0.intersects(draft.range) },
                text: joined(draft.words),
                words: draft.words)
        }
    }

    private struct Draft {
        let speaker: SpeakerID
        var words: [TimedWord]
        var range: TimeRange { TimeRange(start: words.first!.range.start, end: words.last!.range.end) }
    }

    private static func group(_ attributed: [(SpeakerID, TimedWord)]) -> [Draft] {
        var drafts: [Draft] = []
        for (speaker, word) in attributed.sorted(by: { $0.1.range.start < $1.1.range.start }) {
            if let last = drafts.last, last.speaker == speaker,
               word.range.start - last.range.end <= maxPause {
                drafts[drafts.count - 1].words.append(word)
            } else {
                drafts.append(Draft(speaker: speaker, words: [word]))
            }
        }
        return drafts
    }

    private static func speaker(for range: TimeRange, in segments: [SpeakerSegment]) -> SpeakerID? {
        segments.min { a, b in
            let overlapA = a.range.overlap(with: range), overlapB = b.range.overlap(with: range)
            if overlapA != overlapB { return overlapA > overlapB }
            return a.range.distance(to: range) < b.range.distance(to: range)
        }?.speaker
    }

    /// CJK tokens join without spaces; Latin words get one between them.
    private static func joined(_ words: [TimedWord]) -> String {
        var text = ""
        for word in words {
            let token = word.text.trimmingCharacters(in: .whitespaces)
            if let last = text.unicodeScalars.last, let first = token.unicodeScalars.first,
               isLatin(last), first.isASCII, CharacterSet.alphanumerics.contains(first) {
                text += " "
            }
            text += token
        }
        return text
    }

    private static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "'.,?!".unicodeScalars.contains(scalar))
    }
}
