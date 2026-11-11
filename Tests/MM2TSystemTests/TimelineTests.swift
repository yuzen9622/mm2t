import Testing
@testable import MM2TSystem

@Suite struct RecordingTimelineTests {
    @Test func pausedSpansAreRemovedFromPositions() {
        var timeline = RecordingTimeline(startedAt: 100)
        timeline.pause(at: 110)
        timeline.resume(at: 130)

        #expect(timeline.position(at: 99) == nil)
        #expect(timeline.position(at: 105) == 5)
        #expect(timeline.position(at: 120) == nil)
        #expect(timeline.position(at: 130) == 10)
        #expect(timeline.position(at: 135) == 15)
        #expect(timeline.elapsed(at: 135) == 15)
        #expect(timeline.elapsed(at: 120) == 10)
    }

    @Test func clipCutsABufferStraddlingAPauseOrResume() throws {
        var timeline = RecordingTimeline(startedAt: 0)
        timeline.pause(at: 10)
        timeline.resume(at: 20)

        let beforePause = try #require(timeline.clip(start: 9.99, duration: 0.02))
        #expect(abs(beforePause.position - 9.99) < 1e-9 && beforePause.skip == 0 && abs(beforePause.keep - 0.01) < 1e-9)
        let acrossResume = try #require(timeline.clip(start: 19.99, duration: 0.02))
        #expect(acrossResume.position == 10 && abs(acrossResume.skip - 0.01) < 1e-9 && abs(acrossResume.keep - 0.01) < 1e-9)
        #expect(timeline.clip(start: 15, duration: 0.02) == nil)
    }

    @Test func repeatedPauseOrResumeChangesNothing() {
        var timeline = RecordingTimeline(startedAt: 0)
        let results = [timeline.resume(at: 1), timeline.pause(at: 2), timeline.pause(at: 3),
                       timeline.resume(at: 5), timeline.resume(at: 6)]
        #expect(results == [false, true, false, true, false])
        #expect(timeline.elapsed(at: 7) == 4)
        #expect(timeline.state == .recording)
    }

    @Test func stopEndsTheTimeline() {
        var timeline = RecordingTimeline(startedAt: 0)
        timeline.pause(at: 4)
        timeline.stop(at: 9)
        #expect(timeline.state == .stopped)
        #expect(timeline.elapsed(at: 50) == 4)
        #expect(timeline.position(at: 10) == nil)
        let resumed = timeline.resume(at: 10)
        #expect(!resumed)
    }

    @Test func aResumeStampedBeforeThePauseDoesNotRewindTime() {
        var timeline = RecordingTimeline(startedAt: 0)
        timeline.pause(at: 10)
        timeline.resume(at: 8)
        #expect(timeline.elapsed(at: 12) == 12)
    }
}

@Suite struct TrackAlignerTests {
    @Test func jitterWithinToleranceIsWrittenAsIs() {
        var aligner = TrackAligner(sampleRate: 1000, toleranceSeconds: 0.04)
        let placements = [aligner.place(frames: 100, at: 0.01), aligner.place(frames: 100, at: 0.09)]
        #expect(placements == [.init(padding: 0, skip: 0), .init(padding: 0, skip: 0)])
        #expect(aligner.writtenFrames == 200)
    }

    @Test func aGapBecomesSilence() {
        var aligner = TrackAligner(sampleRate: 1000, toleranceSeconds: 0.04)
        _ = aligner.place(frames: 100, at: 0)
        let result = aligner.place(frames: 100, at: 2.1)
        #expect(result == .init(padding: 2000, skip: 0))
        #expect(aligner.writtenFrames == 2200)
    }

    @Test func audioAheadOfTheTimelineIsTrimmed() {
        var aligner = TrackAligner(sampleRate: 1000, toleranceSeconds: 0.04)
        _ = aligner.place(frames: 1000, at: 0)
        let result = aligner.place(frames: 300, at: 0.8)
        #expect(result == .init(padding: 0, skip: 200))
        #expect(aligner.writtenFrames == 1100)
    }

    @Test func paddingToReachADurationNeverShortens() {
        var aligner = TrackAligner(sampleRate: 1000, toleranceSeconds: 0.04)
        _ = aligner.place(frames: 500, at: 0)
        let paddings = [aligner.padding(toReach: 0.2), aligner.padding(toReach: 1.5)]
        #expect(paddings == [0, 1000])
        #expect(aligner.writtenFrames == 1500)
    }
}
