import Foundation

/// Merges STT word timestamps with diarization into utterances.
public enum Alignment {
    /// A pause longer than this starts a new utterance even when the speaker does not change.
    static let maxPause: TimeInterval = 1.5

    /// Each remote word goes to the segment it overlaps most, or the nearest segment when it falls
    /// in a gap. Mic words go to `micSegments` the same way, and are all `.me` when there are none.
    /// `overlaps` are the remote track's, so only its speakers are marked with them.
    public static func utterances(
        me: [TimedWord],
        remote: [TimedWord],
        segments: [SpeakerSegment],
        overlaps: [TimeRange],
        micSegments: [SpeakerSegment] = []
    ) -> [Utterance] {
        let mine = group(me.map { (speaker(for: $0.range, in: micSegments) ?? .me, $0) })
        let remoteSpeakers = Set(segments.map(\.speaker)).subtracting([.me])
        let theirs = group(remote.compactMap { word in
            speaker(for: word.range, in: segments).map { ($0, word) }
        })
        let drafts = (mine + theirs).sorted { ($0.range.start, $0.speaker.rawValue) < ($1.range.start, $1.speaker.rawValue) }
        return drafts.enumerated().map { index, draft in
            Utterance(
                id: UtteranceID("u\(index + 1)"),
                speaker: draft.speaker,
                range: draft.range,
                isOverlapping: remoteSpeakers.contains(draft.speaker) && overlaps.contains { $0.intersects(draft.range) },
                text: joined(draft.words),
                words: draft.words)
        }
    }

    /// A run this long of mic words that the remote track also has, each within `repeatWindow` of
    /// its twin, is the call coming out of the speakers too quietly for the echo removal to notice.
    static let repeatRun = 4
    static let repeatWindow: TimeInterval = 1

    /// `mic` without the stretches that repeat `remote`. Punctuation neither counts toward a run nor breaks one.
    /// A remote word is the twin of one mic word only, so saying 對對對對 to a single 對 is not a repeat.
    static func dropping(repeatsOf remote: [TimedWord], from mic: [TimedWord]) -> [TimedWord] {
        func spoken(_ word: TimedWord) -> String? {
            let text = word.text.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters).union(.symbols)).lowercased()
            return text.isEmpty ? nil : text
        }
        var heard: [String: [TimeInterval]] = [:]
        for word in remote {
            if let text = spoken(word) { heard[text, default: []].append(word.range.start) }
        }
        guard !heard.isEmpty else { return mic }
        var dropped = Set<Int>(), run: [Int] = [], length = 0
        func close() {
            if length >= repeatRun { dropped.formUnion(run) }
            run = []
            length = 0
        }
        var last: TimeInterval?
        for (index, word) in mic.enumerated() {
            // A pause ends the stretch: what follows it is judged afresh.
            if let last, word.range.start - last > repeatWindow { close() }
            last = word.range.end
            guard let text = spoken(word) else {
                if !run.isEmpty { run.append(index) }
                continue
            }
            if let twin = heard[text]?.firstIndex(where: { abs($0 - word.range.start) <= repeatWindow }) {
                heard[text]!.remove(at: twin)
                run.append(index)
                length += 1
            } else {
                close()
            }
        }
        close()
        return mic.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
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
