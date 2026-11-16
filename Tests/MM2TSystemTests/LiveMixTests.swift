import Foundation
import Testing
@testable import MM2TSystem

@Suite struct LiveMixTests {
    @Test func tracksAreSummedWherePositionsMatchAndClipped() {
        var mix = LiveMix(positions: [0, 0], lag: 4_000)
        mix.add([0.25, 0.5, 0.75], track: 0, at: 0)
        mix.add([0.25, 0.75, 0.5], track: 1, at: 0)
        #expect(mix.take() == [0.5, 1, 1])
        #expect(mix.take().isEmpty)
        #expect(mix.cursor == 3)
    }

    @Test func theMixWaitsForTheTrackBehindUpToTheLag() {
        var mix = LiveMix(positions: [0, 0], lag: 4)
        mix.add([Float](repeating: 0.1, count: 3), track: 1, at: 0)
        #expect(mix.take().isEmpty, "the mic has written nothing and the remote is within the lag")
        mix.add([Float](repeating: 0.1, count: 7), track: 1, at: 3)
        // Remote reached 10; the mic is held for at most 4 frames.
        #expect(mix.take().count == 6)
        // The mic's late samples for frames already sent are dropped; the rest are summed.
        mix.add([Float](repeating: 0.2, count: 10), track: 0, at: 0)
        let next = mix.take()
        #expect(next.count == 4)
        #expect(next.allSatisfy { abs($0 - 0.3) < 0.0001 })
    }

    @Test func aStreamStartedMidRecordingBeginsWhereTheFurthestTrackIs() {
        var mix = LiveMix(positions: [16_000, 15_000], lag: 4_000)
        mix.add([Float](repeating: 0.5, count: 2_000), track: 1, at: 15_000)
        mix.add([Float](repeating: 0.5, count: 1_000), track: 0, at: 16_000)
        let mixed = mix.take()
        #expect(mixed.count == 1_000)
        #expect(mixed.allSatisfy { $0 == 1 })
    }

    @Test func thePipelineTapSeesExactlyWhatIsWritten() throws {
        let url = try temporaryDirectory().appending(path: "remote.wav")
        let pipeline = try TrackPipeline(track: .remote, url: url, sampleRate: 16_000)
        var timeline = RecordingTimeline(startedAt: 1000)
        #expect(pipeline.takeWritten() == nil)
        pipeline.setTapping(true)
        let samples = (0..<1_600).map { Float($0 % 100) / 200 }
        write(samples, to: pipeline.ring, hostSeconds: 1000, rate: 16_000)
        pipeline.drain(timeline)
        pipeline.padSilence(upTo: 0.2)
        let taken = try #require(pipeline.takeWritten())
        #expect(taken.start == 0)
        #expect(taken.samples.count == 3_200)
        #expect(Array(taken.samples.prefix(1_600)) == samples)
        #expect(pipeline.takeWritten()?.start == 3_200)
        timeline.stop(at: 1001)
        try pipeline.finish(duration: 0.2)
    }
}
