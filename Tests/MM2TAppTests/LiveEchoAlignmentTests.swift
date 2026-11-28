import Foundation
import MM2TCore
import MM2TLocal
import MM2TSystem
import Testing
@testable import MM2TApp

private actor EchoBoundarySTT: TranscriptionProvider {
    private(set) var pieces: [Range<Int>] = []

    func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) throws -> TranscribedWords {
        let pcm = try WAVFormat.read(audio)
        let start = Int(audio.deletingPathExtension().lastPathComponent.split(separator: "-").last!)!
        pieces.append(start..<start + pcm.samples.count)
        return .unlabeled([TimedWord("speech", 0, min(0.1, pcm.duration))])
    }
}

private struct EchoPairSTT: TrackTranscriber {
    let words: [TimedWord]

    func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) throws -> TranscribedWords {
        Issue.record("expected the paired STT route")
        return .unlabeled([])
    }

    func transcribeTracks(_ tracks: [[Float]], hints: [String]) throws -> [[TimedWord]] {
        #expect(tracks.count == 2)
        return [words, words]
    }
}

private actor EchoSpeakerSession: StreamingDiarizationSession {
    private var counts: [Track: Int] = [:]
    func append(samples: [Float], track: Track) { counts[track, default: 0] += samples.count }
    func snapshot(tracks: [Track: URL], final: Bool) -> StreamingDiarizationSnapshot {
        let mic = Diarization(segments: [.init(cluster: ClusterID("S1"), range: TimeRange(start: 0, end: 10))],
                              overlaps: [], embeddings: [:])
        let remote = Diarization(segments: [.init(cluster: ClusterID("S1"), range: TimeRange(start: 8, end: 10))],
                                 overlaps: [], embeddings: [:])
        return StreamingDiarizationSnapshot(diarizations: [.me: mic, .remote: remote],
                                            processedSeconds: counts.mapValues { Double($0) / 16_000 })
    }
}

@MainActor @Suite struct LiveEchoAlignmentTests {
    @Test func quietCutsKeepEveryNonfinalPieceOnTheGlobalEchoGrid() async throws {
        let rate = 16_000, grid = Int(EchoCanceller.profileFrame * 16_000)
        let total = 30 * rate + 137
        let samples = (0..<total).map { index -> Int16 in
            let seconds = Double(index) / Double(rate)
            let withinPair = seconds.truncatingRemainder(dividingBy: 2)
            // The quiet window begins off the 50 ms grid, exercising sample-level QuietCut.
            return withinPair >= 1.001 && withinPair < 1.311 ? 0 : (index % 2 == 0 ? 8000 : -8000)
        }
        let directory = try temporaryDirectory()
        let mic = directory.appending(path: "mic.wav"), remote = directory.appending(path: "remote.wav")
        try WAVFormat.write(WAVAudio(sampleRate: rate, samples: samples), to: mic)
        try WAVFormat.write(WAVAudio(sampleRate: rate, samples: [Int16](repeating: 0, count: total)), to: remote)
        let stt = EchoBoundarySTT()
        let live = LiveTranscriber(mic: mic, remote: remote, chain: TranscriptionChain([.init(.cloud, stt)]),
                                   hints: [], scratch: directory.appending(path: "pieces"), pieceSeconds: 3)
        await live.advance()
        let inProgress = await stt.pieces
        #expect(inProgress.count > 5)
        #expect(inProgress.allSatisfy { $0.lowerBound % grid == 0 && $0.upperBound % grid == 0 })
        #expect(await live.finish(mic: mic, remote: remote) != nil)
        let pieces = await stt.pieces.sorted { $0.lowerBound < $1.lowerBound }
        #expect(pieces.first?.lowerBound == 0 && pieces.last?.upperBound == total)
        #expect(zip(pieces, pieces.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        #expect(pieces.reduce(0) { $0 + $1.count } == total)
        var profile = EchoProfile(frameDuration: EchoCanceller.profileFrame, before: [], after: [])
        for piece in pieces {
            profile = profile.appending(EchoCanceller.unchangedProfile(mic: Array(samples[piece]), sampleRate: rate),
                                        at: Double(piece.lowerBound) / Double(rate))
        }
        let whole = EchoCanceller.unchangedProfile(mic: samples, sampleRate: rate)
        #expect(profile == whole,
                "piece boundaries must neither duplicate frames nor move the final energy samples")
    }

    @Test func liveFeedsOneAdaptiveFilterAcrossPiecesAndKeepsTheSamePlaybackPCM() async throws {
        let rate = 16_000, count = 8 * rate, delay = 1_354
        var seed: UInt64 = 754
        let render = (0..<count).map { _ -> Int16 in
            seed = seed &* 6364136223846793005 &+ 1
            return Int16(truncatingIfNeeded: seed >> 48) / 2
        }
        let capture = (0..<count).map { index -> Int16 in
            index < delay ? 0 : render[index - delay] / 3
        }
        let directory = try temporaryDirectory()
        let mic = directory.appending(path: "mic.wav"), remote = directory.appending(path: "remote.wav")
        try WAVFormat.write(WAVAudio(sampleRate: rate, samples: capture), to: mic)
        try WAVFormat.write(WAVAudio(sampleRate: rate, samples: render), to: remote)
        let stt = EchoWordReplay([TimedWord("echo", 1, 1.1)], failOnMicCall: 2)
        let live = LiveTranscriber(mic: mic, remote: remote, chain: TranscriptionChain([.init(.cloud, stt)]),
                                   hints: [], scratch: directory.appending(path: "pieces"), pieceSeconds: 4,
                                   keepsPlayback: true)
        await live.advance()
        _ = try #require(await live.finish(mic: mic, remote: remote))
        let calls = await stt.pieces
        try #require(calls.count >= 3)
        #expect(calls[1].frames == calls[2].frames)
        #expect(calls[1].samples == calls[2].samples, "A retry must not feed those frames to AEC3 a second time")
        let pieces = [calls[0]] + calls.dropFirst(2)
        let reference = try #require(AEC3())
        for piece in pieces {
            let heard = Array(capture[piece.frames]), played = Array(render[piece.frames])
            #expect(piece.samples == reference.clean(mic: heard, remote: played).samples)
        }
        let second = pieces[1]
        let cold = try #require(AEC3())
        #expect(second.samples != cold.clean(mic: Array(capture[second.frames]), remote: Array(render[second.frames])).samples)
        let playback = try WAVFormat.read(PlaybackMic.url(beside: mic))
        #expect(playback.samples == pieces.flatMap(\.samples))
    }

    @Test func appendedPlaybackEvidenceStaysOnTheGlobalEchoGrid() {
        let frame = EchoCanceller.profileFrame
        let prefix = EchoProfile(frameDuration: frame, before: [0.01], after: [0.01])
        let piece = EchoProfile(frameDuration: frame, before: [0.0025, 0.0001], after: [0.001, 0.0001],
                                remote: [0.01, 0])
        let joined = prefix.appending(piece, at: 0.1)
        let missing = TimedWord("unmeasured", 0.05, 0.1)
        let echo = TimedWord("echo", 0.15, 0.2)
        #expect(joined.remote == [0, nil, 0.01, 0])
        #expect(joined.droppingEcho(from: [missing]) == [missing])
        #expect(joined.droppingEcho(from: [echo]).isEmpty)
    }

    @Test func pairedLiveTranscriptionDropsTheQuietMicTailButNotRemoteWords() async throws {
        let rate = 16_000
        var seed: UInt64 = 42
        let playback = (0..<2 * rate).map { _ -> Int16 in
            seed = seed &* 6364136223846793005 &+ 1
            return seed >> 63 == 0 ? -8000 : 8000
        }
        let played = playback + Array(repeating: Int16(0), count: 2 * rate)
        let heard = playback + (0..<2 * rate).map { sample in
            let level: Int16 = sample < 3 * rate / 2 ? 64 : 5000
            return sample.isMultiple(of: 2) ? level : -level
        }
        let directory = try temporaryDirectory()
        let mic = directory.appending(path: "mic.wav"), remote = directory.appending(path: "remote.wav")
        try WAVFormat.write(WAVAudio(sampleRate: rate, samples: heard), to: mic)
        try WAVFormat.write(WAVAudio(sampleRate: rate, samples: played), to: remote)
        let words = [TimedWord("tail", 2.55, 2.85)]
        let stt = EchoPairSTT(words: words)
        let live = LiveTranscriber(mic: mic, remote: remote, chain: TranscriptionChain([.init(.local, stt)]),
                                   hints: [], scratch: directory.appending(path: "paired"))
        let result = try #require(await live.finish(mic: mic, remote: remote))
        #expect(result.me.words.isEmpty)
        #expect(result.remote.words == words)
    }

    @Test func liveRunKeepsItsQuietTailAcrossThePieceBoundary() async throws {
        let rate = 16_000
        let boundary = 3 * rate
        let total = 6 * rate
        var seed: UInt64 = 42
        let played = (0..<total).map { sample -> Int16 in
            seed = seed &* 6364136223846793005 &+ 1
            let time = Double(sample) / Double(rate)
            guard (3.15..<3.23).contains(time) || (4..<5.5).contains(time) else { return 0 }
            return seed >> 63 == 0 ? -8000 : 8000
        }
        let heard = played.enumerated().map { sample, playback -> Int16 in
            if playback != 0 { return playback }
            let time = Double(sample) / Double(rate)
            let level: Int16 = time < 2.85 ? 5000 : time < 3.15 ? 0 : 64
            return sample.isMultiple(of: 2) ? level : -level
        }
        let directory = try temporaryDirectory()
        let mic = directory.appending(path: "mic.wav"), remote = directory.appending(path: "remote.wav")
        try WAVFormat.write(WAVAudio(sampleRate: rate, samples: heard), to: mic)
        try WAVFormat.write(WAVAudio(sampleRate: rate, samples: played), to: remote)
        let words = [TimedWord("loud", 2.5, 2.96), TimedWord("tail", 3.44, 3.69)]
        let stt = EchoWordReplay(words)
        let live = LiveTranscriber(mic: mic, remote: remote, chain: TranscriptionChain([.init(.cloud, stt)]),
                                   hints: [], scratch: directory.appending(path: "pieces"), pieceSeconds: 4)
        await live.advance()
        #expect(await stt.pieces.map(\.frames) == [0..<boundary])
        let result = try #require(await live.finish(mic: mic, remote: remote))
        #expect(await stt.pieces.map(\.frames) == [0..<boundary, boundary..<total])
        #expect(result.me.words == words)
    }

    @Test func unfilteredRoomSpeechPreventsAnEchoFragmentFromDeletingTheWholeSpeaker() async throws {
        let rate = 16_000
        func noise(_ count: Int, seed: UInt64, magnitude: Int16) -> [Int16] {
            var state = seed
            return (0..<count).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return state >> 63 == 0 ? magnitude : -magnitude
            }
        }
        let voice = noise(8 * rate, seed: 1, magnitude: 9000)
        let echo = noise(2 * rate, seed: 2, magnitude: 3000)
        let filtered = try #require(EchoCanceller.clean(mic: echo, remote: echo, sampleRate: rate))
        #expect(filtered.echo.isEcho([TimeRange(start: 0, end: 2)]))
        let directory = try temporaryDirectory()
        let mic = directory.appending(path: "mic.wav"), remote = directory.appending(path: "remote.wav")
        try WAVFormat.write(WAVAudio(sampleRate: rate, samples: voice + echo), to: mic)
        try WAVFormat.write(WAVAudio(sampleRate: rate, samples: [Int16](repeating: 0, count: voice.count) + echo), to: remote)
        let world = try World()
        let setup = PipelineSetup(library: world.library, voiceprints: world.app.voiceprints,
                                  credentials: world.credentials, catalog: world.catalog)
        guard case .ready(let pipeline) = try setup.build(world.app.settings.settings) else {
            Issue.record("test pipeline is unavailable")
            return
        }
        let processor = LiveRecordingProcessor(pipeline: pipeline, session: EchoSpeakerSession(),
                                               scratch: directory.appending(path: "speakers"))
        await processor.append(mic: mic, remote: remote, range: 0..<8 * rate)
        await processor.append(mic: mic, remote: remote, range: 8 * rate..<10 * rate)
        await processor.finish()
        let meeting = try await world.library.create(Recording(micTrack: mic, remoteTrack: remote, highlights: [],
                                                               metadata: MeetingMetadata(title: "Room and echo", startedAt: Date(), duration: 10)))
        let transcription = Transcription(me: TrackTranscript(source: .cloud, content: .unlabeled([TimedWord("房間正常發言", 1, 2)])),
                                          remote: TrackTranscript(source: .cloud, content: .unlabeled([TimedWord("遠端發言", 8, 9)])))
        #expect(try await processor.attach(transcription, to: meeting.id))
        let attached = try await world.library.meeting(meeting.id)
        #expect(attached.transcription?.me.words == transcription.me.words)
        #expect(attached.utterances.map(\.text) == ["房間正常發言", "遠端發言"])
    }
}

private actor EchoWordReplay: TranscriptionProvider {
    struct Piece {
        let frames: Range<Int>
        let words: [TimedWord]
        let samples: [Int16]
    }

    let words: [TimedWord]
    private(set) var pieces: [Piece] = []
    private let failOnMicCall: Int?

    init(_ words: [TimedWord], failOnMicCall: Int? = nil) {
        self.words = words
        self.failOnMicCall = failOnMicCall
    }

    private struct Retryable: Error {}

    func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) throws -> TranscribedWords {
        let name = audio.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("me-") else { return .unlabeled([TimedWord("remote", 0, 0.01)]) }
        let startFrame = try #require(Int(name.dropFirst(3)))
        let pcm = try WAVFormat.read(audio)
        let offset = Double(startFrame) / Double(pcm.sampleRate)
        let end = Double(startFrame + pcm.samples.count) / Double(pcm.sampleRate)
        // A stored word belongs to the piece in which it starts, but its endpoint is not
        // clipped: the recording-wide gate must measure the original word span.
        let local = words.filter { $0.range.start >= offset && $0.range.start < end }.map {
            TimedWord($0.text, $0.range.start - offset, $0.range.end - offset)
        }
        pieces.append(Piece(frames: startFrame..<startFrame + pcm.samples.count, words: local, samples: pcm.samples))
        if pieces.count == failOnMicCall { throw Retryable() }
        return .unlabeled(local)
    }
}
