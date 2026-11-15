import Foundation
import Testing
@testable import MM2TCore

@Suite struct AlignmentTests {
    private func words(_ prefix: String, count: Int, offset: TimeInterval = 0) -> [TimedWord] {
        (0..<count).map { TimedWord("\(prefix)\($0)", offset + Double($0), offset + Double($0 + 1)) }
    }

    private func remote(_ words: [TimedWord]) -> [Utterance] {
        Alignment.utterances(me: [], remote: words,
                             segments: [.init(speaker: SpeakerID("r1"), range: TimeRange(start: 0, end: 300))],
                             overlaps: [])
    }

    @Test func continuousSpeechClosesTwentySecondUtterancesWithoutLosingWords() {
        let input = words("word", count: 65)
        let result = remote(input)
        #expect(result.map(\.range) == [TimeRange(start: 0, end: 20), TimeRange(start: 20, end: 40),
                                       TimeRange(start: 40, end: 60), TimeRange(start: 60, end: 65)])
        #expect(result.flatMap(\.words) == input)
        #expect(result.map(\.id.rawValue) == ["u1", "u2", "u3", "u4"])
        #expect(result[0].text == input.prefix(20).map(\.text).joined(separator: " "))
    }

    @Test func extendingARecordingKeepsClosedUtteranceIDsAndTextStable() {
        let input = words("word", count: 85)
        let first = remote(Array(input.prefix(45)))
        let second = remote(Array(input.prefix(65)))
        let final = remote(input)
        #expect(Array(first.prefix(2)) == Array(second.prefix(2)))
        #expect(Array(first.prefix(2)) == Array(final.prefix(2)))
        #expect(Array(second.prefix(3)) == Array(final.prefix(3)))
        #expect(first.map(\.id) == Array(final.prefix(first.count)).map(\.id),
                "only the open tail's text and end time may grow")
        #expect(final.flatMap(\.words) == input)
    }

    @Test func exactlyTwentySecondsStaysTogetherAndALongSingleWordIsNeverSplit() {
        let exact = remote(words("word", count: 20))
        #expect(exact.count == 1 && exact[0].range == TimeRange(start: 0, end: 20))
        let input = [TimedWord("before", 0, 1), TimedWord("long-word", 1, 27),
                     TimedWord("after", 27, 28), TimedWord("next", 28, 29)]
        let result = remote(input)
        #expect(result.map(\.text) == ["before", "long-word", "after next"])
        #expect(result.flatMap(\.words) == input)
        #expect(result[1].range.duration == 26)
    }

    @Test func theSameSpeakerOnTwoTracksStillHasSeparateStableUtterances() {
        let mic = words("mic", count: 65, offset: 0.5)
        let call = words("call", count: 65)
        let segment = SpeakerSegment(speaker: .me, range: TimeRange(start: 0, end: 100))
        func align(_ count: Int) -> [Utterance] {
            Alignment.utterances(me: Array(mic.prefix(count)), remote: Array(call.prefix(count)),
                                 segments: [segment], overlaps: [], micSegments: [segment])
        }
        let prefix = align(45)
        let full = align(65)
        #expect(Array(prefix.prefix(4)) == Array(full.prefix(4)))
        #expect(full.count == 8)
        for utterance in full {
            #expect(utterance.range.duration <= 20)
            let fromMic = utterance.words.first!.text.hasPrefix("mic")
            #expect(utterance.words.allSatisfy { $0.text.hasPrefix(fromMic ? "mic" : "call") })
        }
        #expect(full.flatMap(\.words).filter { $0.text.hasPrefix("mic") } == mic)
        #expect(full.flatMap(\.words).filter { $0.text.hasPrefix("call") } == call)
    }

    @Test func pausesAndSpeakerChangesStillCloseShortUtterances() {
        let input = [TimedWord("one", 0, 1), TimedWord("two", 2.5, 3),
                     TimedWord("three", 4.6, 5), TimedWord("four", 5, 6)]
        let result = Alignment.utterances(me: [], remote: input,
                                         segments: [.init(speaker: SpeakerID("r1"), range: TimeRange(start: 0, end: 5)),
                                                    .init(speaker: SpeakerID("r2"), range: TimeRange(start: 5, end: 6))],
                                         overlaps: [])
        #expect(result.map(\.text) == ["one two", "three", "four"])
        #expect(result.map(\.speaker.rawValue) == ["r1", "r1", "r2"])
        #expect(result.flatMap(\.words) == input)
    }
}
