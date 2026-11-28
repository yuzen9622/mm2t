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

    @Test func aec3SuppressesResidualEchoWithoutSuppressingDoubleTalk() throws {
        let rate = Self.rate
        let played = Self.noise(8 * rate, seed: 1, level: 0.5)
        let voice = played.indices.map { index -> Double in
            let time = Double(index) / Double(rate) - 4
            guard (0..<2).contains(time) else { return 0 }
            let syllable = 0.6 + 0.4 * sin(2 * .pi * 3.6 * time)
            let phase = 2 * Double.pi * (170 * time + 2 * sin(2 * .pi * 0.6 * time))
            let formants = 0.48 * sin(phase) + 0.31 * sin(2 * phase) + 0.18 * sin(4 * phase) + 0.12 * sin(7 * phase)
            return 0.45 * syllable * formants
        }
        let mic = played.indices.map { index -> Int16 in
            let first = index >= 1_354 ? 0.3 * played[index - 1_354] : 0
            let second = index >= 1_500 ? 0.15 * played[index - 1_500] : 0
            return Int16((first + second + voice[index]) * 32_767)
        }
        let remote = played.map { Int16($0 * 32_767) }
        let aec = try #require(AEC3())
        let linear = try #require(EchoCanceller.clean(mic: mic, remote: remote, sampleRate: rate))
        let cleaned = aec.clean(mic: mic, remote: remote)
        let echo = 2 * rate..<3 * rate
        let talking = 4 * rate + 4_000..<6 * rate - 4_000
        let cleanVoice = voice.map { Int16($0 * 32_767) }
        #expect(Self.decibels(linear.samples[echo]) - Self.decibels(cleaned.samples[echo]) > 6)
        #expect(abs(Self.decibels(cleanVoice[talking]) - Self.decibels(cleaned.samples[talking])) < 1.5)
        #expect((aec.estimatedDelayMilliseconds ?? 0) > 0)
    }

    @Test func uncoupledMicrophoneIsBitIdenticalDespiteLoudPlayback() throws {
        let remote = Self.room.remote
        let mic = Self.noise(remote.count, seed: 8, level: 0.08).map { Int16($0 * 32767) }
        let aec = try #require(AEC3())
        let result = aec.clean(mic: mic, remote: remote)
        #expect(result.samples == mic)
        #expect(result.echo.before == result.echo.after)
        #expect(!result.echo.speakerFrames().contains(true))
    }

    @Test func quietWordsJustAfterSpeakerPlaybackAreDropped() throws {
        let remote = Array(Self.room.remote.prefix(2 * Self.rate)) + Array(repeating: Int16(0), count: 2 * Self.rate)
        var mic = remote
        for sample in (Int(2.55 * Double(Self.rate))..<Int(2.85 * Double(Self.rate))) {
            mic[sample] = sample.isMultiple(of: 2) ? 64 : -64
        }
        let echo = try #require(EchoCanceller.clean(mic: mic, remote: remote, sampleRate: Self.rate)).echo
        let words = [TimedWord("quiet tail", 2.55, 2.85)]
        let transcript = TrackTranscript(source: .cloud, content: .unlabeled(words))
        #expect(!echo.isEcho(words[0].range), "the existing 5 dB word rule cannot catch the tail")
        #expect(transcript.dropping(echo).words.isEmpty)
    }

    private static func speakerProfile(evidence: Float = 4, loudFrame: Int? = nil) -> EchoProfile {
        var after = [Float](repeating: 0.0001, count: 600)
        if let loudFrame { after[loudFrame] = 0.0025 }
        var before = after
        // At the words the old 5 dB test sees no loss. Only nearby playback provides evidence.
        for index in 40..<100 { before[index] *= evidence }
        var playback = [Float](repeating: 0, count: 600)
        for index in 40..<160 { playback[index] = 0.01 }
        return EchoProfile(frameDuration: 0.05, before: before, after: after, remote: playback)
    }

    @Test func quietRunDuringPlaybackIsDropped() {
        let words = [TimedWord("quiet", 5, 5.2), TimedWord("run", 5.7, 5.9)]
        let profile = Self.speakerProfile()
        #expect(words.allSatisfy { !profile.isEcho($0.range) })
        #expect(profile.droppingEcho(from: words).isEmpty)
    }

    @Test func loudDoubleTalkKeepsTheEntireRun() {
        let words = [TimedWord("quiet", 5, 5.2), TimedWord("loud", 5.7, 5.9)]
        let profile = Self.speakerProfile(loudFrame: 116)
        #expect(profile.droppingEcho(from: words) == words)
    }

    @Test func aQuietTailAfterASpokenPauseStaysWithTheLoudWord() {
        let words = [TimedWord("loud", 5.5, 5.9), TimedWord("tail", 6.83, 7.1)]
        let profile = Self.speakerProfile(loudFrame: 116)
        #expect(profile.droppingEcho(from: [words[1]]).isEmpty)
        #expect(profile.droppingEcho(from: words) == words)
    }

    @Test func headphonesKeepTheSameQuietRun() {
        let words = [TimedWord("quiet", 5, 5.2), TimedWord("run", 5.7, 5.9)]
        let profile = Self.speakerProfile(evidence: 1)
        #expect(profile.droppingEcho(from: words) == words)
    }

    @Test func quietRunWithoutNearbyPlaybackIsKept() {
        let words = [TimedWord("quiet", 9.2, 9.5)]
        let profile = Self.speakerProfile()
        #expect(profile.droppingEcho(from: words) == words)
    }

    @Test func aLongerGapSeparatesQuietAndLoudWords() {
        let words = [TimedWord("quiet", 5, 5.15), TimedWord("loud", 7.2, 7.4)]
        let profile = Self.speakerProfile(loudFrame: 146)
        #expect(words.allSatisfy { !profile.isEcho($0.range) })
        #expect(profile.droppingEcho(from: words) == Array(words.suffix(1)))
    }

    @Test func playbackEvidenceIsTimedAtTheMicsMeasuredLag() throws {
        let lag = Self.rate / 10
        let noise = Self.noise(Self.rate, seed: 42, level: 0.5).map { Int16($0 * 32767) }
        let remote = Array(repeating: Int16(0), count: Self.rate) + noise + Array(repeating: 0, count: Self.rate)
        let mic = Array(repeating: Int16(0), count: lag) + Array(remote.dropLast(lag))
        let echo = try #require(EchoCanceller.clean(mic: mic, remote: remote, sampleRate: Self.rate)).echo
        #expect(echo.remote[20] == 0 && echo.remote[21] == 0)
        #expect((echo.remote[22] ?? 0) > 0.01)
    }

    @Test func aSilentRemoteTrackLeavesNothingToRemove() {
        let (mic, remote) = Self.room
        #expect(EchoCanceller.clean(mic: mic, remote: [Int16](repeating: 0, count: remote.count), sampleRate: Self.rate) == nil)
    }

    @Test func unfilteredProfilesPreserveEnergyIncludingThePartialTail() {
        let frame = Int(EchoCanceller.profileFrame * Double(Self.rate))
        let mic = [Int16](repeating: 8192, count: frame) + [Int16](repeating: 16384, count: 137)
        let profile = EchoCanceller.unchangedProfile(mic: mic, sampleRate: Self.rate)
        #expect(profile.frameDuration == 0.05)
        #expect(profile.before == [0.0625, 0.25])
        #expect(profile.before == profile.after)
        #expect(!profile.isEcho([TimeRange(start: 0, end: Double(mic.count) / Double(Self.rate))]))
        let empty = EchoCanceller.unchangedProfile(mic: [], sampleRate: Self.rate)
        #expect(empty.before.isEmpty && empty.after.isEmpty)
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
