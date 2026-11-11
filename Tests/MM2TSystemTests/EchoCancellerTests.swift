import Foundation
import MM2TCore
import Testing
@testable import MM2TSystem

@Suite struct EchoCancellerTests {
    static let rate = 16_000

    /// Repeatable noise, as full of frequencies as speech is.
    static func noise(_ count: Int, seed: UInt64, level: Double) -> [Double] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Double(state >> 40) / Double(1 << 23) - 1) * level
        }
    }

    static func decibels(_ samples: ArraySlice<Int16>) -> Double {
        10 * log10(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count) + 1e-9)
    }

    /// Eight seconds: the remote track plays throughout and reaches the mic 85 ms late off two
    /// surfaces; someone in the room talks from 4 s to 6 s.
    static let room: (mic: [Int16], remote: [Int16]) = {
        let count = 8 * rate
        let played = noise(count, seed: 1, level: 0.5), voice = noise(count, seed: 2, level: 0.3)
        let mic = (0..<count).map { index -> Double in
            let echo = (index >= 1354 ? 0.3 * played[index - 1354] : 0) + (index >= 1500 ? 0.15 * played[index - 1500] : 0)
            return echo + ((4 * rate..<6 * rate).contains(index) ? voice[index] : 0)
        }
        return (mic.map { Int16($0 * 32767) }, played.map { Int16($0 * 32767) })
    }()

    @Test func theSpeakersEchoIsRemovedAndTheRoomIsKept() throws {
        let (mic, remote) = Self.room
        let cleaned = try #require(EchoCanceller.clean(mic: mic, remote: remote, sampleRate: Self.rate))

        #expect(cleaned.samples.count == mic.count)
        let echoOnly = 1 * Self.rate..<3 * Self.rate, talking = 4 * Self.rate + 4000..<6 * Self.rate - 4000
        #expect(Self.decibels(mic[echoOnly]) - Self.decibels(cleaned.samples[echoOnly]) > 15)
        #expect(abs(Self.decibels(mic[talking]) - Self.decibels(cleaned.samples[talking])) < 1.5)

        #expect(cleaned.echo.isEcho(TimeRange(start: 2, end: 2.3)))
        #expect(!cleaned.echo.isEcho(TimeRange(start: 5, end: 5.3)))
    }

    @Test func aSilentRemoteTrackLeavesNothingToRemove() {
        let (mic, remote) = Self.room
        #expect(EchoCanceller.clean(mic: mic, remote: [Int16](repeating: 0, count: remote.count), sampleRate: Self.rate) == nil)
    }

    @Test func aRecordingIsCleanedIntoAFileOfTheSameLength() throws {
        let directory = try temporaryDirectory()
        let (mic, remote) = Self.room
        let micURL = directory.appending(path: "mic.wav"), remoteURL = directory.appending(path: "remote.wav")
        try WAVFormat.write(WAVAudio(sampleRate: Self.rate, samples: mic), to: micURL)
        // The remote file ends a second early; that last second of the mic is kept as recorded.
        try WAVFormat.write(WAVAudio(sampleRate: Self.rate, samples: Array(remote[..<(7 * Self.rate)])), to: remoteURL)

        let cleaned = try #require(try EchoRemover().clean(mic: micURL, remote: remoteURL))
        defer { try? FileManager.default.removeItem(at: cleaned.audio) }
        let audio = try WAVFormat.read(cleaned.audio)
        #expect(audio.samples.count == mic.count)
        #expect(Array(audio.samples[(7 * Self.rate)...]) == Array(mic[(7 * Self.rate)...]))
        #expect(cleaned.echo.isEcho(TimeRange(start: 2, end: 2.3)))

        try WAVFormat.write(WAVAudio(sampleRate: Self.rate, samples: [Int16](repeating: 0, count: mic.count)), to: remoteURL)
        #expect(try EchoRemover().clean(mic: micURL, remote: remoteURL) == nil)
    }
}
