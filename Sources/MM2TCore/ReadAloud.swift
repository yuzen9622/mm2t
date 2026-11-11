import Foundation

/// Whether a recording is the user reading a given passage, judged loosely: the point is that a
/// real voice said roughly these words, not that every one was pronounced or recognized right.
public enum ReadAloud {
    /// Part of the passage that must turn up, in order, in what was heard.
    public static let requiredCoverage = 0.5

    /// The share of `passage`'s letters and digits that appear in `heard` in the same order.
    /// Punctuation, spacing, case and Simplified against Traditional characters do not count.
    public static func coverage(of passage: String, in heard: String) -> Double {
        let wanted = normalized(passage), got = normalized(heard)
        guard !wanted.isEmpty else { return 1 }
        var previous = [Int](repeating: 0, count: got.count + 1)
        for a in wanted {
            var current = [0]
            for (j, b) in got.enumerated() {
                current.append(a == b ? previous[j] + 1 : max(previous[j + 1], current[j]))
            }
            previous = current
        }
        return Double(previous.last ?? 0) / Double(wanted.count)
    }

    private static func normalized(_ text: String) -> [Character] {
        Array(TraditionalChinese.convert(text).lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Seconds in which someone was speaking: 20 ms frames louder than `floor` (a 16-bit amplitude).
    /// A quiet room sits far below it and speech into a laptop mic far above.
    public static func speechSeconds(_ samples: [Int16], sampleRate: Int, floor: Double = 250) -> TimeInterval {
        let frame = max(1, sampleRate / 50)
        var voiced = 0
        for start in stride(from: 0, to: samples.count - frame + 1, by: frame) {
            let energy = samples[start..<start + frame].reduce(0.0) { $0 + Double($1) * Double($1) }
            if (energy / Double(frame)).squareRoot() > floor { voiced += 1 }
        }
        return Double(voiced) / 50
    }
}
