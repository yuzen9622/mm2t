import AVFoundation
import Foundation
import MM2TCore
import Testing
@testable import MM2TSystem

@Suite struct WAVFileTests {
    @Test func roundTripsSamplesWithClipping() throws {
        let url = try temporaryDirectory().appending(path: "a.wav")
        let writer = try WAVWriter(url: url, sampleRate: 16_000)
        [0, 0.5, -0.5, 1, -1, 3, -3, .nan].withUnsafeBufferPointer { writer.append($0) }
        writer.appendSilence(frames: 2)
        try writer.close()

        let audio = try WAVFormat.read(url)
        #expect(audio.sampleRate == 16_000)
        #expect(audio.samples == [0, 16383, -16383, 32767, -32767, 32767, -32767, 0, 0, 0])
    }

    @Test func anInterruptedFileIsReadableUpToTheLastFlushByStandardReaders() throws {
        let url = try temporaryDirectory().appending(path: "crash.wav")
        let writer = try WAVWriter(url: url, sampleRate: 16_000)
        let second = [Float](repeating: 0.25, count: 16_000)
        for _ in 0 ..< 3 {
            second.withUnsafeBufferPointer { writer.append($0) }
            try writer.flush()
        }
        second.withUnsafeBufferPointer { writer.append($0) }
        // The process dies here: never closed, the fourth second never flushed.

        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 48_000)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(try WAVFormat.read(url).samples.count == 48_000)
    }

    @Test func repairCoversBytesWrittenAfterTheLastHeaderUpdateAndDropsATornFrame() throws {
        let url = try temporaryDirectory().appending(path: "torn.wav")
        let writer = try WAVWriter(url: url, sampleRate: 8_000)
        [Float](repeating: 0.1, count: 8_000).withUnsafeBufferPointer { writer.append($0) }
        try writer.flush()
        // Audio reached the disk but the header update after it did not, ending mid-sample.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x11, count: 4_001))
        try handle.close()

        #expect(try WAVFormat.repair(url) == 10_000.0 / 8_000)
        #expect(try AVAudioFile(forReading: url).length == 10_000)
        #expect(try WAVFormat.repair(url) == 10_000.0 / 8_000)
    }

    @Test func rejectsFilesThatAreNotMono16BitWAV() throws {
        let url = try temporaryDirectory().appending(path: "x.wav")
        try Data("not audio".utf8).write(to: url)
        #expect(throws: WAVFormatError.notWAV) { try WAVFormat.read(url) }
    }
}

@Suite struct RecordingRecoveryTests {
    @Test func aCrashedSessionBecomesARecordingTheLibraryAccepts() async throws {
        let directory = try temporaryDirectory().appending(path: "session")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest = RecordingManifest(title: "Standup", startedAt: Date(timeIntervalSince1970: 1_000),
                                         platform: .zoom, targetBundleID: "us.zoom.xos")
        manifest.highlights = [1.5]
        try manifest.write(to: directory)
        let mic = try WAVWriter(url: directory.appending(path: RecordingManifest.micFile), sampleRate: 16_000)
        let remote = try WAVWriter(url: directory.appending(path: RecordingManifest.remoteFile), sampleRate: 16_000)
        let audio = [Float](repeating: 0.2, count: 16_000)
        for _ in 0 ..< 2 { audio.withUnsafeBufferPointer { mic.append($0); remote.append($0) } }
        try mic.flush()
        try remote.flush()
        audio.withUnsafeBufferPointer { remote.append($0) }
        try remote.flush()
        #expect(RecordingRecovery.isInterrupted(directory))

        let recording = try RecordingRecovery.recover(directory)

        #expect(recording.metadata.duration == 3)
        #expect(recording.metadata.title == "Standup")
        #expect(recording.metadata.platform == .zoom)
        #expect(recording.highlights == [Highlight(time: 1.5)])
        #expect(!RecordingRecovery.isInterrupted(directory))
        let library = MeetingLibrary(root: try temporaryDirectory())
        let meeting = try await library.create(recording)
        #expect(meeting.audio.micFile == "mic.wav")
        #expect(try WAVFormat.read(await library.audioURL(meeting, track: .remote)).duration == 3)
    }
}

@Suite struct AudioLevelTests {
    @Test func fullScaleSineReadsMinusThreeDecibels() {
        let sine = (0 ..< 4_800).map { Float(sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
        let level = sine.withUnsafeBufferPointer(AudioLevel.init(samples:))
        #expect(abs(level.rmsDBFS - -3.01) < 0.05)
        #expect(abs(level.peak - 1) < 0.001)
        #expect(abs(level.meter() - (60 - 3.01) / 60) < 0.01)
    }

    @Test func silenceIsTheFloorAndAnEmptyWindowIsSilent() {
        let level = [Float](repeating: 0, count: 10).withUnsafeBufferPointer(AudioLevel.init(samples:))
        #expect(level.rmsDBFS == -160)
        #expect(level.meter() == 0)
        #expect(AudioLevel.Accumulator().level == .silent)
    }

    @Test func accumulatorCombinesChunksIntoOneWindow() {
        var accumulator = AudioLevel.Accumulator()
        [Float](repeating: 0.5, count: 100).withUnsafeBufferPointer { accumulator.add($0) }
        [Float](repeating: 0, count: 300).withUnsafeBufferPointer { accumulator.add($0) }
        #expect(accumulator.level == AudioLevel(rms: 0.25, peak: 0.5))
    }
}
