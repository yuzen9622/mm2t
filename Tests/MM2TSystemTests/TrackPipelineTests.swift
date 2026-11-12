import CoreAudio
import Foundation
import Testing
@testable import MM2TSystem

/// Drives two track pipelines the way the IO threads and the recorder do, with devices at
/// different rates, a pause and a device gap, and checks the files stay on one timeline.
@Suite struct TrackPipelineTests {
    @Test func bothTracksStayAlignedAcrossPauseAndDeviceGap() throws {
        let directory = try temporaryDirectory()
        let mic = try TrackPipeline(track: .me, url: directory.appending(path: "mic.wav"), sampleRate: 16_000)
        let remote = try TrackPipeline(track: .remote, url: directory.appending(path: "remote.wav"), sampleRate: 16_000)
        let start = 1_000.0
        var timeline = RecordingTimeline(startedAt: start)

        // A click at host second 2 on both tracks, a pause from 3 to 5, a second click at 6, and the
        // mic device away from 6.5 to 7.5.
        let clicks: Set<Int> = [2, 6]
        func feed(_ pipeline: TrackPipeline, rate: Double, from: Double, to: Double) {
            let chunk = Int(rate / 100)
            for index in 0 ..< Int(((to - from) * rate).rounded()) / chunk {
                let t = from + Double(index * chunk) / rate
                let first = Int(((t - start) * rate).rounded())
                let samples = (0 ..< chunk).map { i -> Float in
                    let second = Double(first + i) / rate
                    return clicks.contains { abs(second - Double($0)) < 0.005 } ? 0.9 : 0.01
                }
                write(samples, to: pipeline.ring, hostSeconds: t, rate: rate)
            }
        }
        for second in 0 ..< 9 {
            let from = start + Double(second)
            if second == 3 { timeline.pause(at: from) }
            if second == 5 { timeline.resume(at: from) }
            switch second {
            case 6: feed(mic, rate: 48_000, from: from, to: from + 0.5)
            case 7: feed(mic, rate: 24_000, from: from + 0.5, to: from + 1)
            default: feed(mic, rate: second < 6 ? 48_000 : 24_000, from: from, to: from + 1)
            }
            feed(remote, rate: 44_100, from: from, to: from + 1)
            mic.drain(timeline)
            remote.drain(timeline)
        }
        timeline.stop(at: start + 9)
        let duration = timeline.elapsed(at: start + 9)
        try mic.finish(duration: duration)
        try remote.finish(duration: duration)

        let micAudio = try WAVFormat.read(directory.appending(path: "mic.wav"))
        let remoteAudio = try WAVFormat.read(directory.appending(path: "remote.wav"))
        #expect(abs(micAudio.duration - 7) < 0.05)
        #expect(abs(remoteAudio.duration - 7) < 0.05)
        // Paused time is gone: the click starting at host 5.995 lands at recording 3.995 on both tracks.
        let micClicks = clickTimes(micAudio), remoteClicks = clickTimes(remoteAudio)
        #expect(micClicks.count == 2 && remoteClicks.count == 2)
        for (clicks, expected) in [(micClicks, [1.995, 3.995]), (remoteClicks, [1.995, 3.995])] {
            #expect(zip(clicks, expected).allSatisfy { abs($0 - $1) < 0.003 }, "\(clicks)")
        }
        #expect(zip(micClicks, remoteClicks).allSatisfy { abs($0 - $1) < 0.002 }, "\(micClicks) \(remoteClicks)")
        // The device gap became silence, not a shift of later audio.
        let gap = micAudio.samples[Int(4.7 * 16_000) ..< Int(5.3 * 16_000)]
        #expect(gap.allSatisfy { $0 == 0 })
    }

    @Test func pausedAudioStillMovesTheMeters() throws {
        let pipeline = try TrackPipeline(track: .me, url: try temporaryDirectory().appending(path: "mic.wav"), sampleRate: 16_000)
        var timeline = RecordingTimeline(startedAt: 0)
        timeline.pause(at: 0)
        write([Float](repeating: 0.5, count: 480), to: pipeline.ring, hostSeconds: 1, rate: 48_000)
        pipeline.drain(timeline)
        #expect(pipeline.takeLevel().peak == 0.5)
        #expect(pipeline.aligner.writtenFrames == 0)
    }

    private func clickTimes(_ audio: WAVAudio) -> [Double] {
        var times: [Double] = []
        for (index, sample) in audio.samples.enumerated() where abs(Int(sample)) > 16_000 {
            let time = Double(index) / Double(audio.sampleRate)
            if times.last.map({ time - $0 > 0.5 }) ?? true { times.append(time) }
        }
        return times
    }
}

func write(_ samples: [Float], to ring: CaptureRing, hostSeconds: Double, rate: Double) {
    var samples = samples
    samples.withUnsafeMutableBytes { bytes in
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
        ring.write(&list, hostTime: AudioConvertNanosToHostTime(UInt64(hostSeconds * 1_000_000_000)), sampleRate: rate)
    }
}

/// One folder per test process, removed when it exits; one a crashed run left behind is swept an hour later.
let testScratch: URL = {
    let files = FileManager.default
    let parent = files.temporaryDirectory.appending(path: "mm2t-test-runs")
    for old in (try? files.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.creationDateKey])) ?? []
    where (try? old.resourceValues(forKeys: [.creationDateKey]).creationDate).flatMap { $0 } ?? .distantFuture
        < Date(timeIntervalSinceNow: -3600) {
        try? files.removeItem(at: old)
    }
    atexit { try? FileManager.default.removeItem(at: testScratch) }
    return parent.appending(path: UUID().uuidString)
}()

func temporaryDirectory() throws -> URL {
    let url = testScratch.appending(path: "mm2t-system-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
