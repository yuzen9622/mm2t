import Foundation
import Testing
@testable import MM2TSystem

@Suite struct CaptionTrackTests {
    @Test func captionSourceFollowsMeetingCaptureMode() {
        #expect(SystemAudioCapture.off.captionTrack == .me)
        #expect(SystemAudioCapture.app("us.zoom.xos").captionTrack == .remote)
        #expect(SystemAudioCapture.automatic(ignoring: []).captionTrack == .remote)
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
