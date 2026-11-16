import Foundation

/// A stretch of caption text that arrived at one moment, so a view can fade in only what is new.
public struct CaptionRun: Equatable, Sendable {
    public let text: String
    public let arrived: Date
    /// The unfinished segment, which the service may still revise.
    public let isPartial: Bool
}

/// Remembers when each character of the captions on screen arrived. A revised partial keeps the
/// times of its unchanged beginning, so only the changed tail fades in again; a segment that
/// settles keeps the times its words had as a partial.
public struct CaptionArrivals: Sendable {
    /// The most recent text worth keeping on a two-line bar; older segments are left out.
    public static let characterBudget = 240

    private struct Mark: Sendable {
        let offset: Int
        let date: Date
    }

    private var segmentMarks: [Int: [Mark]] = [:]
    private var partialMarks: [Mark] = []
    private var partialText = ""

    public init() {}

    /// The newest segments that fit `characterBudget`, always at least the last one.
    public static func recent(_ segments: [LiveCaptions.Segment], budget: Int = characterBudget) -> [LiveCaptions.Segment] {
        var count = 0
        var start = segments.endIndex
        while start > segments.startIndex {
            let length = segments[start - 1].text.count
            if start < segments.endIndex, count + length > budget { break }
            count += length
            start -= 1
        }
        return Array(segments[start...])
    }

    /// Records arrivals for what is shown now and returns it as runs in reading order.
    public mutating func update(segments: [LiveCaptions.Segment], partial: String, now: Date) -> [CaptionRun] {
        for segment in segments where segmentMarks[segment.id] == nil {
            // The segment that settles the partial inherits its times; any other is new.
            let shared = Self.commonPrefix(partialText, segment.text)
            if shared > 0 {
                segmentMarks[segment.id] = Self.marks(partialMarks, keeping: shared, length: segment.text.count, now: now)
            } else {
                segmentMarks[segment.id] = [Mark(offset: 0, date: now)]
            }
            partialText = ""
            partialMarks = []
        }
        let shown = Set(segments.map(\.id))
        segmentMarks = segmentMarks.filter { shown.contains($0.key) }

        let shared = Self.commonPrefix(partialText, partial)
        partialMarks = partial.isEmpty ? [] : Self.marks(partialMarks, keeping: shared, length: partial.count, now: now)
        partialText = partial

        var runs: [CaptionRun] = []
        var previous = ""
        for segment in segments {
            let joiner = Self.joiner(previous, segment.text)
            runs += Self.runs(joiner + segment.text, marks: segmentMarks[segment.id] ?? [], shift: joiner.count, partial: false)
            previous = segment.text
        }
        if !partial.isEmpty {
            let joiner = Self.joiner(previous, partial)
            runs += Self.runs(joiner + partial, marks: partialMarks, shift: joiner.count, partial: true)
        }
        return runs
    }

    private static func marks(_ old: [Mark], keeping shared: Int, length: Int, now: Date) -> [Mark] {
        var kept = old.filter { $0.offset < shared }
        if shared < length { kept.append(Mark(offset: shared, date: now)) }
        return kept
    }

    private static func runs(_ text: String, marks: [Mark], shift: Int, partial: Bool) -> [CaptionRun] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        // The joiner arrives with the first character after it.
        var bounds = marks.map { (offset: $0.offset == 0 ? 0 : $0.offset + shift, date: $0.date) }
        if bounds.first?.offset != 0 { bounds.insert((0, marks.first?.date ?? .distantPast), at: 0) }
        var runs: [CaptionRun] = []
        for (index, bound) in bounds.enumerated() {
            let end = index + 1 < bounds.count ? bounds[index + 1].offset : characters.count
            guard bound.offset < end, end <= characters.count else { continue }
            runs.append(CaptionRun(text: String(characters[bound.offset..<end]), arrived: bound.date, isPartial: partial))
        }
        return runs
    }

    static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }

    /// Chinese and Japanese run on without spaces; anything else gets one between segments.
    public static func joiner(_ previous: String, _ next: String) -> String {
        guard let last = previous.last, let first = next.first else { return "" }
        return isWide(last) || isWide(first) ? "" : " "
    }

    private static func isWide(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F, 0x3000...0x303F: true
            default: false
            }
        }
    }
}
