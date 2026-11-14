import Foundation
import MM2TApp
import MM2TCore
import Observation
import Testing

struct KaraokeTimingTests {
    @MainActor @Test func playbackTicksDoNotInvalidateTheWholeTranscript() {
        let playhead = TranscriptPlayhead()
        playhead.follow([0, 10, 20])
        playhead.sample(time: 0, duration: 30, isPlaying: true)
        let invalidated = Box(false)
        withObservationTracking {
            _ = playhead.currentLine
            _ = playhead.isPlaying
        } onChange: { invalidated.set(true) }
        for tick in 1..<190 {
            playhead.sample(time: Double(tick) / 20, duration: 30, isPlaying: true)
        }
        #expect(!invalidated.get, "the scroll content stays unchanged within the same line")
        playhead.sample(time: 10, duration: 30, isPlaying: true)
        #expect(invalidated.get)
        #expect(playhead.currentLine == 1)

        invalidated.set(false)
        withObservationTracking { _ = playhead.isPlaying } onChange: { invalidated.set(true) }
        playhead.sample(time: 10, duration: 30, isPlaying: false)
        #expect(invalidated.get, "pausing must redraw all lines at full brightness")
    }

    @Test func pausingRestoresEveryLineToFullBrightness() {
        for current in [nil, 0, 1, 2] as [Int?] {
            for index in 0..<3 {
                #expect(KaraokeTiming.state(of: index, current: current, isPlaying: false) == .idle)
            }
        }
        #expect(KaraokeTiming.state(of: 0, current: 1, isPlaying: true) == .played)
        #expect(KaraokeTiming.state(of: 1, current: 1, isPlaying: true) == .current)
        #expect(KaraokeTiming.state(of: 2, current: 1, isPlaying: true) == .upcoming)
    }

    @Test func followingChangesAtLineBoundariesAndSupportsSeeking() {
        let starts: [TimeInterval] = [1, 10, 20]
        #expect(KaraokeTiming.currentLine(starts: starts, at: 0) == nil)
        #expect(KaraokeTiming.currentLine(starts: starts, at: 1) == 0)
        #expect(KaraokeTiming.currentLine(starts: starts, at: 9) == 0)
        #expect(KaraokeTiming.currentLine(starts: starts, at: 10) == 1)
        #expect(KaraokeTiming.currentLine(starts: starts, at: 99) == 2)
        #expect(KaraokeTiming.currentLine(starts: starts, at: 2) == 0)
        #expect(KaraokeTiming.currentLine(starts: [], at: 2) == nil)
    }

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
