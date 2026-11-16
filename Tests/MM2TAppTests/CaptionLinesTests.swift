import Foundation
import Testing
@testable import MM2TApp

@Suite struct CaptionLinesTests {
    /// Ten characters to a line.
    let breaker: (String) -> [Int] = { text in
        stride(from: 0, to: text.count, by: 10).map { min(10, text.count - $0) }
    }
    let t0 = Date(timeIntervalSince1970: 0)

    private func segment(_ id: Int, _ text: String) -> LiveCaptions.Segment {
        LiveCaptions.Segment(id: id, text: text, started: .distantPast, ended: .distantPast)
    }

    @Test func aThirdLineMovesEverythingUpByOne() {
        var lines = CaptionLines()
        lines.update(segments: [], partial: "一二三四五六七八九十甲乙", now: t0, breakLines: breaker)
        #expect(lines.lines.map(\.index) == [0, 1])
        lines.update(segments: [], partial: "一二三四五六七八九十甲乙丙丁戊己庚辛壬癸子丑", now: t0, breakLines: breaker)
        #expect(lines.lines.map(\.index) == [1, 2])
        #expect(lines.lines.map(\.text) == ["甲乙丙丁戊己庚辛壬癸", "子丑"])
    }

    @Test func aRevisionThatShortensTheTextNeverBringsAScrolledLineBack() {
        var lines = CaptionLines()
        lines.update(segments: [], partial: "一二三四五六七八九十甲乙丙丁戊己庚辛壬癸子丑", now: t0, breakLines: breaker)
        lines.update(segments: [], partial: "一二三四五六七八九十甲乙", now: t0, breakLines: breaker)
        #expect(lines.lines.map(\.index) == [1])
        #expect(lines.lines.map(\.text) == ["甲乙"])
        // A revision inside the scrolled-away words leaves them away too.
        lines.update(segments: [], partial: "一二三四五", now: t0, breakLines: breaker)
        #expect(lines.lines.allSatisfy { $0.index >= 1 })
    }

    @Test func scrolledAwaySegmentsLeaveTheLayoutWithoutReflowingWhatIsShown() {
        var lines = CaptionLines()
        var segments: [LiveCaptions.Segment] = []
        for id in 0..<12 {
            segments.append(segment(id, "第\(id)句話說完了。"))
            lines.update(segments: segments, partial: "", now: t0, breakLines: breaker)
            #expect(lines.lines.count <= CaptionLines.visibleLines)
        }
        let all = segments.map(\.text).joined()
        #expect(all.hasSuffix(lines.lines.map(\.text).joined()), "the shown lines are the end of the text")
        let shownStart = all.count - lines.lines.map(\.text).joined().count
        #expect(shownStart % 10 == 0, "the shown lines start where a line started from the beginning")
        #expect(lines.lines.last?.index == (all.count - 1) / 10)
    }

    @Test func replacingAShownTranslationKeepsTheTimesOfItsCommonStart() {
        #expect(CaptionArrivals.commonPrefix("我們後面再說", "我們後來再說") == 3)
        #expect(CaptionArrivals.commonPrefix("", "abc") == 0)
        var arrivals = CaptionArrivals()
        let t1 = t0.addingTimeInterval(1)
        _ = arrivals.update(segments: [segment(0, "我們明天，")], partial: "", now: t0)
        let runs = arrivals.update(segments: [segment(0, "我們明天見。")], partial: "", now: t1)
        #expect(runs == [CaptionRun(text: "我們明天", arrived: t0, isPartial: false),
                         CaptionRun(text: "見。", arrived: t1, isPartial: false)])
    }

    @Test func aFinalTranslationReplacesThePartialOneInPlace() {
        var lines = CaptionLines()
        let t1 = t0.addingTimeInterval(1), t2 = t0.addingTimeInterval(2)
        lines.update(segments: [], partial: "明天見，", now: t0, breakLines: breaker)
        // The segment settles showing the same words: nothing arrives again.
        lines.update(segments: [segment(0, "明天見，")], partial: "", now: t1, breakLines: breaker)
        #expect(lines.lines.flatMap(\.runs).map(\.arrived) == [t0])
        // Its own translation differs only at the end: only that end arrives.
        lines.update(segments: [segment(0, "明天見，好嗎？")], partial: "", now: t2, breakLines: breaker)
        let runs = lines.lines.flatMap(\.runs)
        #expect(runs.map(\.text) == ["明天見，", "好嗎？"])
        #expect(runs.map(\.arrived) == [t0, t2])
    }
}
