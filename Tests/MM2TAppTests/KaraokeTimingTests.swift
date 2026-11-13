import Foundation
import MM2TApp
import MM2TCore
import Testing

struct KaraokeTimingTests {
    @Test func charactersTakeTheTimesOfTheWordsThatSpellThem() {
        let words = [TimedWord("好", 1, 1.2), TimedWord("，", 1.2, 1.25), TimedWord("OK", 2, 2.4)]
        #expect(KaraokeTiming.starts(of: "好，OK", words: words, spans: []) == [1, 1.2, 2, 2.2])
    }

    @Test func aCorrectedLineIsSpreadOverItsTimeInstead() {
        let words = [TimedWord("沒", 0, 1), TimedWord("改", 1, 2)]
        let starts = KaraokeTiming.starts(of: "改過了啦", words: words, spans: [TimeRange(start: 0, end: 4)])
        #expect(starts == [0, 1, 2, 3])
    }

    @Test func rewrittenTextSkipsTheGapsWhereSomeoneElseSpoke() {
        let starts = KaraokeTiming.spread(count: 4, over: [TimeRange(start: 10, end: 12), TimeRange(start: 20, end: 22)])
        #expect(starts == [10, 11, 20, 21])
    }

    @Test func theCharacterBeingSpokenIsPartlyHeard() {
        let starts: [TimeInterval] = [0, 1, 2]
        #expect(KaraokeTiming.progress(starts, end: 3, at: -1) == (0, 0))
        let middle = KaraokeTiming.progress(starts, end: 3, at: 1.5)
        #expect(middle.heard == 1 && abs(middle.fraction - 0.5) < 0.001)
        #expect(KaraokeTiming.progress(starts, end: 3, at: 5) == (3, 0))
    }
}
