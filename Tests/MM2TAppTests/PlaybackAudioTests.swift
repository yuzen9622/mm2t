import Foundation
import MM2TCore
import MM2TSystem
import Testing
@testable import MM2TApp

@Suite struct PlaybackAudioTests {
    @Test @MainActor func missingAudioFinishesUnavailable() async {
        let player = TwoTrackPlayer()
        let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        #expect(player.status == .loading)
        player.play(from: 0)
        #expect(!player.isPlaying)
        await player.load(mic: missing, remote: missing)
        #expect(player.status == .unavailable)
        #expect(player.duration == 0)
    }

    @Test @MainActor func singleTrackLoadsAndReloadClearsDuration() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mm2t-player-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mic = folder.appending(path: "mic.wav")
        let missing = folder.appending(path: "missing.wav")
        try WAVFormat.write(WAVAudio(sampleRate: 16_000, samples: .init(repeating: 0, count: 32_000)), to: mic)
        let player = TwoTrackPlayer()
        await player.load(mic: mic, remote: missing)
        #expect(player.status == .ready)
        #expect(abs(player.duration - 2) < 0.01)
        player.seek(to: 1)
        #expect(abs(player.currentTime - 1) < 0.01)
        #expect(!player.isPlaying)
        await player.load(mic: missing, remote: missing)
        #expect(player.status == .unavailable)
        #expect(player.duration == 0)
        #expect(player.currentTime == 0)
    }

    @Test @MainActor func malformedAudioFinishesFailed() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "mm2t-invalid-\(UUID()).wav")
        try Data("not audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let player = TwoTrackPlayer()
        await player.load(mic: file, remote: file)
        #expect(player.status == .failed)
        #expect(player.duration == 0)
    }

    /// A mic that hears the remote track half as loud, 85 ms late.
    private static func echoedTracks(in folder: URL) throws -> (mic: URL, remote: URL, echoed: [Int16]) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mic = folder.appending(path: "mic.wav"), remote = folder.appending(path: "remote.wav")
        let rate = 16_000, delay = 1360
        var state: UInt64 = 42
        let source: [Int16] = (0..<rate * 8).map { _ in
            state = state &* 6364136223846793005 &+ 1
            return Int16(Int(state >> 48) / 4 - 8192)
        }
        let echoed = [Int16](repeating: 0, count: delay) + source.dropLast(delay).map { $0 / 2 }
        try WAVFormat.write(WAVAudio(sampleRate: rate, samples: source), to: remote)
        try WAVFormat.write(WAVAudio(sampleRate: rate, samples: echoed), to: mic)
        return (mic, remote, echoed)
    }

    @Test func playbackRemovesDelayedSystemAudioFromMicOnceWithoutChangingOriginals() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mm2t-playback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (mic, remote, echoed) = try Self.echoedTracks(in: folder)
        let originalMic = try Data(contentsOf: mic), originalRemote = try Data(contentsOf: remote)

        let audio = PlaybackAudio.prepare(mic: mic, remote: remote)
        #expect(audio.mic == PlaybackMic.url(beside: mic))
        #expect(audio.remote == remote)
        let filtered = try WAVFormat.read(audio.mic)
        #expect(filtered.samples.count == echoed.count)
        let rate = 16_000, range = rate..<7 * rate
        func energy(_ samples: ArraySlice<Int16>) -> Double {
            samples.reduce(0) { $0 + Double($1) * Double($1) }
        }
        #expect(energy(filtered.samples[range]) < energy(echoed[range]) / 100)
        #expect(try Data(contentsOf: mic) == originalMic)
        #expect(try Data(contentsOf: remote) == originalRemote)

        // The kept track is what the next open plays; it is not cleaned again.
        try Data("kept".utf8).write(to: audio.mic)
        #expect(PlaybackAudio.prepare(mic: mic, remote: remote).mic == audio.mic)
        #expect(try Data(contentsOf: audio.mic) == Data("kept".utf8))
    }

    @Test func silentRemoteKeepsTheOriginalMicrophoneAndRemembersThereWasNoEcho() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mm2t-playback-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mic = folder.appending(path: "mic.wav"), remote = folder.appending(path: "remote.wav")
        try WAVFormat.write(WAVAudio(sampleRate: 16_000, samples: .init(repeating: 1000, count: 16_000)), to: mic)
        try WAVFormat.write(WAVAudio(sampleRate: 16_000, samples: .init(repeating: 0, count: 16_000)), to: remote)
        #expect(PlaybackMic.kept(beside: mic) == nil)
        let audio = PlaybackAudio.prepare(mic: mic, remote: remote)
        #expect(audio.mic == mic)
        #expect(PlaybackMic.kept(beside: mic) == mic)
        #expect(FileManager.default.fileExists(atPath: mic.path))
        #expect(FileManager.default.fileExists(atPath: remote.path))
    }

    @Test @MainActor func playsAsRecordedAtOnceThenSwitchesToTheCleanedTrackInPlace() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mm2t-player-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (mic, remote, _) = try Self.echoedTracks(in: folder)

        let player = TwoTrackPlayer()
        await player.load(mic: mic, remote: remote)
        #expect(player.status == .ready)
        #expect(abs(player.duration - 8) < 0.01)
        #expect(PlaybackMic.kept(beside: mic) == nil)
        player.seek(to: 3)
        await player.cleaning?.value
        #expect(PlaybackMic.kept(beside: mic) == PlaybackMic.url(beside: mic))
        #expect(player.status == .ready)
        #expect(abs(player.currentTime - 3) < 0.01)
        #expect(!player.isPlaying)

        let reopened = TwoTrackPlayer()
        await reopened.load(mic: mic, remote: remote)
        #expect(reopened.status == .ready)
        #expect(reopened.cleaning == nil)
    }
}
