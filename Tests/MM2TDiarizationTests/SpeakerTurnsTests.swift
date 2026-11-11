import Foundation
import MM2TCore
import Testing
@testable import MM2TDiarization

@Suite struct SpeakerTurnsTests {
    private func ranges(_ segments: [Diarization.Segment], _ cluster: String) -> [TimeRange] {
        segments.filter { $0.cluster.rawValue == cluster }.map(\.range)
    }

    @Test func bridgesSameSpeakerPausesShorterThanHalfASecondOnly() {
        let bridged = SpeakerTurns.bridgingGaps([
            segment("S1", 0, 2), segment("S1", 2.4, 3), segment("S1", 3.6, 5),
            segment("S2", 2.1, 2.3),
        ], shorterThan: 0.5)

        #expect(ranges(bridged, "S1") == [TimeRange(start: 0, end: 3), TimeRange(start: 3.6, end: 5)])
        #expect(ranges(bridged, "S2") == [TimeRange(start: 2.1, end: 2.3)], "another speaker's turn is untouched")
    }

    @Test func bridgingNeverJoinsAcrossDifferentSpeakersAndKeepsTimeOrder() {
        let bridged = SpeakerTurns.bridgingGaps([
            segment("S2", 1.2, 2), segment("S1", 0, 1), segment("S1", 2.2, 3),
        ], shorterThan: 0.5)

        #expect(bridged.map(\.cluster.rawValue) == ["S1", "S2", "S1"])
        #expect(ranges(bridged, "S1") == [TimeRange(start: 0, end: 1), TimeRange(start: 2.2, end: 3)])
    }

    @Test func overlapsAreWhereTwoDifferentSpeakersTalkAtOnce() {
        let overlaps = SpeakerTurns.overlaps([
            segment("S1", 0, 5),
            segment("S2", 4, 7),
            segment("S3", 6, 8),
            segment("S1", 4.5, 6),  // same speaker twice is not an overlap by itself
            segment("S2", 9, 10), segment("S3", 10, 11),  // touching turns do not overlap
        ])

        #expect(overlaps == [TimeRange(start: 4, end: 7)], "S1+S2 at 4-6 and S2+S3 at 6-7 form one region")
    }

    @Test func cleanPiecesExcludeOtherSpeakersAndCutTwoToEightSeconds() {
        let pieces = SpeakerTurns.cleanPieces([
            segment("S1", 0, 20),
            segment("S2", 9, 10),
            segment("S2", 30, 31.5),
        ], within: 60)

        #expect(pieces[ClusterID("S1")] == [
            TimeRange(start: 0, end: 8),
            TimeRange(start: 10, end: 18),
            TimeRange(start: 18, end: 20),
        ], "the 1 s before S2 cuts in is dropped, the 2 s tail is kept")
        #expect(pieces[ClusterID("S2")] == [], "1.5 s of clean speech is too short for one piece")
    }

    @Test func cleanPiecesStopAtTheEndOfTheAudio() {
        let pieces = SpeakerTurns.cleanPieces([segment("S1", 0, 30)], within: 11)
        #expect(pieces[ClusterID("S1")] == [TimeRange(start: 0, end: 8), TimeRange(start: 8, end: 11)])
    }

    @Test func centroidAveragesDirectionsNotMagnitudes() throws {
        let mean = try #require(SpeakerTurns.centroid([[10, 0], [0, 1], [0, 0]]))
        #expect(Embedding(mean).cosineSimilarity(to: Embedding([1, 1])) > 0.9999)
        #expect(SpeakerTurns.centroid([]) == nil)
    }
}
