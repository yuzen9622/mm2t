import AppKit
import CoreText
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

/// Where the caption bar's 18 pt rounded medium text wraps, so the bar can lay out whole lines
/// itself. Spaced scripts (English, Korean, German, Czech) break between words and unspaced ones
/// (Chinese, Japanese) between characters, with CoreText's rules for punctuation. CoreText breaks
/// Hangul between syllables, so a break inside a spaced word moves back to the space before it.
@MainActor
public struct CaptionLineBreaker {
    public let width: CGFloat

    public init(width: CGFloat) { self.width = width }

    static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: 18, weight: .medium)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 18) } ?? base
    }()

    /// The number of characters on each line of `text`.
    public func counts(_ text: String) -> [Int] {
        let attributed = NSAttributedString(string: text, attributes: [.font: Self.font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length
        var counts: [Int] = []
        var start = 0
        var index = text.startIndex
        // A hair narrower than the bar, so SwiftUI never finds a line too long for it.
        let room = Double(max(width - 2, 40))
        while start < length {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, room)
            guard count > 0 else { break }
            var end = String.Index(utf16Offset: start + count, in: text)
            if end < text.endIndex, let last = text[index..<end].last, Self.isSpacedWord(last), Self.isSpacedWord(text[end]),
               let space = text[index..<end].lastIndex(where: \.isWhitespace) {
                end = text.index(after: space)
                count = end.utf16Offset(in: text) - start
            }
            counts.append(text[index..<end].count)
            index = end
            start += count
        }
        return counts
    }

    /// A letter or digit of a script written with spaces between words.
    static func isSpacedWord(_ character: Character) -> Bool {
        guard character.isLetter || character.isNumber else { return false }
        return !character.unicodeScalars.contains { $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value) }
    }

    /// How wide `text` is in the bar's font, to check that a line fits.
    public func width(of text: String) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: Self.font]).size().width
    }
}
