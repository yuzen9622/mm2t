import Foundation
import MM2TSystem
import Testing
@testable import MM2TApp

@Suite struct PlaybackAudioTests {
    @Test func playbackRemovesDelayedSystemAudioFromMicWithoutChangingOriginals() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mm2t-playback-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
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
        let originalMic = try Data(contentsOf: mic), originalRemote = try Data(contentsOf: remote)

        let audio = PlaybackAudio.prepare(mic: mic, remote: remote)
        defer { audio.removeTemporaryFiles() }
        #expect(audio.mic != mic)
        #expect(audio.remote == remote)
        let filtered = try WAVFormat.read(audio.mic)
        #expect(filtered.samples.count == echoed.count)
        let range = rate..<7 * rate
        func energy(_ samples: ArraySlice<Int16>) -> Double {
            samples.reduce(0) { $0 + Double($1) * Double($1) }
        }
        #expect(energy(filtered.samples[range]) < energy(echoed[range]) / 100)
        #expect(try Data(contentsOf: mic) == originalMic)
        #expect(try Data(contentsOf: remote) == originalRemote)
        audio.removeTemporaryFiles()
        #expect(!FileManager.default.fileExists(atPath: audio.mic.path))
        #expect(FileManager.default.fileExists(atPath: mic.path))
    }

    @Test func silentRemoteKeepsTheOriginalMicrophoneAndCleanupCannotDeleteIt() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mm2t-playback-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mic = folder.appending(path: "mic.wav"), remote = folder.appending(path: "remote.wav")
        try WAVFormat.write(WAVAudio(sampleRate: 16_000, samples: .init(repeating: 1000, count: 16_000)), to: mic)
        try WAVFormat.write(WAVAudio(sampleRate: 16_000, samples: .init(repeating: 0, count: 16_000)), to: remote)
        let audio = PlaybackAudio.prepare(mic: mic, remote: remote)
        #expect(audio.mic == mic)
        audio.removeTemporaryFiles()
        #expect(FileManager.default.fileExists(atPath: mic.path))
        #expect(FileManager.default.fileExists(atPath: remote.path))
    }
}
