import Foundation

/// The caption bar's main area as whole lines. Text wraps the way `breakLines` says; when a third
/// line starts, the oldest leaves for good. Lines that scrolled away never come back, even when a
/// revision or a translation shortens or re-wraps the words before them, and the text still on
/// screen is laid out from the start of a line, so nothing above it can re-wrap what is shown.
public struct CaptionLines: Sendable {
    public struct Line: Equatable, Sendable {
        /// Counts every line since the recording started, so a view can tell lines apart as they move.
        public let index: Int
        public let runs: [CaptionRun]

        public var text: String { runs.map(\.text).joined() }
    }

    public static let visibleLines = 2

    public private(set) var lines: [Line] = []
    private var arrivals = CaptionArrivals()
    /// Segments before this one scrolled away entirely and are no longer laid out.
    private var baseID: Int?
    /// The words of the lines that scrolled away, from the start of what is laid out.
    private var consumed = ""
    private var scrolledLines = 0

    public init() {}

    /// Lays out `segments` (as a surface shows them) and the partial after them. `breakLines`
    /// returns how many characters each line of a text holds at the bar's width.
    public mutating func update(segments: [LiveCaptions.Segment], partial: String, now: Date,
                                breakLines: (String) -> [Int]) {
        if segments.isEmpty && partial.isEmpty {
            self = CaptionLines()
            return
        }
        var laid = baseID.map { base in segments.filter { $0.id >= base } } ?? segments
        let runs = arrivals.update(segments: laid, partial: partial, now: now)
        let full = runs.map(\.text).joined()
        if !full.hasPrefix(consumed) {
            // A revision reached words that already scrolled away: they stay away.
            consumed = String(consumed.prefix(CaptionArrivals.commonPrefix(full, consumed)))
        }
        let rest = String(full.dropFirst(consumed.count))
        var counts = rest.isEmpty ? [] : breakLines(rest).filter { $0 > 0 }
        if counts.count > Self.visibleLines {
            let leaving = counts.count - Self.visibleLines
            consumed += rest.prefix(counts.prefix(leaving).reduce(0, +))
            scrolledLines += leaving
            counts.removeFirst(leaving)
        }
        var offset = consumed.count
        lines = counts.enumerated().map { index, count in
            defer { offset += count }
            return Line(index: scrolledLines + index, runs: Self.slice(runs, from: offset, count: count))
        }
        // Segments wholly inside the scrolled-away lines are dropped from the layout.
        while laid.count > 1 {
            let first = laid[0]
            let length = first.text.count + CaptionArrivals.joiner(first.text, laid[1].text).count
            guard consumed.count >= length, consumed.hasPrefix(first.text) else { break }
            consumed.removeFirst(length)
            laid.removeFirst()
            baseID = laid[0].id
        }
    }

    /// The runs' characters from `from` for `count`, split where the runs split.
    static func slice(_ runs: [CaptionRun], from: Int, count: Int) -> [CaptionRun] {
        var result: [CaptionRun] = []
        var position = 0
        let end = from + count
        for run in runs {
            let length = run.text.count
            defer { position += length }
            let start = max(from, position), stop = min(end, position + length)
            guard start < stop else { continue }
            let characters = Array(run.text)
            result.append(CaptionRun(text: String(characters[(start - position)..<(stop - position)]),
                                     arrived: run.arrived, isPartial: run.isPartial))
        }
        return result
    }
}
