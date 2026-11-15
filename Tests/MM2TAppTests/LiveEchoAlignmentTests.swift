import Foundation
import MM2TCore
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
        #expect(profile.before == whole.before && profile.after == whole.after,
                "piece boundaries must neither duplicate frames nor move the final energy samples")
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
