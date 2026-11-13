import Foundation
import MM2TCore

/// When each character of a transcript line is reached during playback, so the line can light up
/// as it is spoken. Whitespace is not counted: it is never shown being "sung".
public enum KaraokeTiming {
    /// One start time per non-whitespace character of `text`. Uses the speech service's word
    /// times when they still spell the text; a line the user corrected, or rewritten text, is
    /// spread evenly over `spans` instead.
    public static func starts(of text: some StringProtocol, words: [TimedWord], spans: [TimeRange]) -> [TimeInterval] {
        let shown = text.filter { !$0.isWhitespace }
        var heard: [(Character, TimeInterval)] = []
        for word in words {
            let letters = word.text.filter { !$0.isWhitespace }
            let step = letters.isEmpty ? 0 : (word.range.end - word.range.start) / Double(letters.count)
            for (offset, letter) in letters.enumerated() {
                heard.append((letter, word.range.start + step * Double(offset)))
            }
        }
        if heard.count == shown.count, zip(heard, shown).allSatisfy({ $0.0 == $1 }) {
            return heard.map(\.1)
        }
        return spread(count: shown.count, over: spans)
    }

    /// `count` characters spaced evenly through the spoken time of `spans`, skipping the gaps
    /// between them, where someone else was talking.
    public static func spread(count: Int, over spans: [TimeRange]) -> [TimeInterval] {
        let spans = spans.filter { $0.end > $0.start }
        let total = spans.reduce(0) { $0 + ($1.end - $1.start) }
        guard count > 0, total > 0 else { return Array(repeating: spans.first?.start ?? 0, count: count) }
        return (0..<count).map { index in
            var offset = total * Double(index) / Double(count)
            for span in spans {
                let length = span.end - span.start
                if offset < length { return span.start + offset }
                offset -= length
            }
            return spans.last!.end
        }
    }

    /// How much of a line has been heard at `time`: the first `heard` characters fully, and the
    /// next one by `fraction` (0 to 1), so it brightens smoothly rather than in a step.
    public static func progress(_ starts: [TimeInterval], end: TimeInterval, at time: TimeInterval) -> (heard: Int, fraction: Double) {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= time { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return (0, 0) }
        let index = low - 1
        let next = index + 1 < starts.count ? starts[index + 1] : max(end, starts[index] + 0.15)
        let length = max(0.04, next - starts[index])
        let fraction = min(1, (time - starts[index]) / length)
        return fraction >= 1 ? (index + 1, 0) : (index, fraction)
    }
}
