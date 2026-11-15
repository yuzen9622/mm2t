import Foundation
import MM2TCore
import MM2TSystem
import Testing
@testable import MM2TApp

private actor RecordingSpeakerSession: StreamingDiarizationSession {
    var counts: [Track: Int] = [:]
    var finals = 0
    func append(samples: [Float], track: Track) { counts[track, default: 0] += samples.count }
    func processedSeconds() -> [Track: TimeInterval] { counts.mapValues { Double($0) / 16_000 } }
    func snapshot(tracks: [Track: URL], final: Bool) throws -> StreamingDiarizationSnapshot {
        if final { finals += 1 }
        for (track, url) in tracks { #expect(try WAVFormat.frameCount(url) == counts[track]) }
        return StreamingDiarizationSnapshot(
            diarizations: [.me: Script.diarization, .remote: Script.diarization],
            processedSeconds: counts.mapValues { Double($0) / 16_000 })
    }
}

@MainActor @Suite struct LiveRecordingProcessingTests {
    func pipeline(_ world: World) throws -> MeetingProcessingPipeline {
        let setup = PipelineSetup(library: world.library, voiceprints: world.app.voiceprints,
                                  credentials: world.credentials, catalog: world.catalog)
        guard case .ready(let pipeline) = try setup.build(world.app.settings.settings) else {
            throw LiveTestError.setup
        }
        return pipeline
    }

    @Test func finalizedRecordingReusesSpeakersButStillGeneratesAllOutputs() async throws {
        let world = try World()
        let original = try await world.recordedMeeting()
        let prepared = try pipeline(world)
        let source = try #require(original.transcription)
        let directory = try temporaryDirectory()
        let mic = directory.appending(path: "mic.wav"), remote = directory.appending(path: "remote.wav")
        try FileManager.default.copyItem(at: await world.library.audioURL(original, track: .me), to: mic)
        try FileManager.default.copyItem(at: await world.library.audioURL(original, track: .remote), to: remote)
        let saved = try await world.library.create(Recording(micTrack: mic, remoteTrack: remote,
                                                            highlights: original.highlights, metadata: original.metadata))
        world.catalog.diarizer.fails.set(true)
        world.catalog.cloud.behavior.set(.failed)
        world.catalog.llm.calls.set([])
        try await prepared.attachRecording(source, diarizations: [.me: Script.diarization, .remote: Script.diarization],
                                           echo: nil, to: saved.id)
        #expect(try await world.library.meeting(saved.id).status == .pending(next: .inferNames))
        await world.queue.run(.process, on: saved.id, using: prepared)
        let result = try await world.library.meeting(saved.id)
        #expect(result.status == .completed)
        #expect(result.utterances == original.utterances)
        #expect(result.speakers == original.speakers)
        #expect(result.outputs.cleaned != nil && result.outputs.digests != nil && result.outputs.summary != nil)
        #expect(!result.outputs.isStale)
        #expect(Set(world.catalog.llm.calls.get) == ["inferNames", "cleanTranscript", "digestPerPerson", "summarize"])
    }

    @Test func speculatingDoesNotPersistDraftOrHideGenerationFailure() async throws {
        let world = try World()
        let prepared = try pipeline(world)
        let draft = await prepared.recordingDraft(
            transcription: Transcription(me: TrackTranscript(source: .cloud, content: .unlabeled(Script.micWords)),
                                         remote: TrackTranscript(source: .cloud, content: .unlabeled(Script.remoteWords))),
            diarizations: [.me: Script.diarization, .remote: Script.diarization], echo: nil,
            metadata: MeetingMetadata(title: "Recording", startedAt: Date(), duration: 35), highlights: [])
        world.catalog.llm.failNext.set(["summarize"])
        #expect(await prepared.precomputeRecording(draft) == false)
        #expect(try await world.library.list().isEmpty)
        #expect(await prepared.precomputeRecording(draft))
        #expect(try await world.library.list().isEmpty)
    }

    @Test func aSilentPrefixAdvancesCoveredAudioWithoutCallingTheLLM() async throws {
        let world = try World()
        let prepared = try pipeline(world)
        let empty = TrackTranscript(source: .cloud, content: .unlabeled([]))
        let speakers = Diarization(segments: [], overlaps: [], embeddings: [:])
        let draft = await prepared.recordingDraft(
            transcription: Transcription(me: empty, remote: empty),
            diarizations: [.me: speakers, .remote: speakers], echo: nil,
            metadata: MeetingMetadata(title: "Recording", startedAt: Date(), duration: 240), highlights: [])
        #expect(draft.utterances.isEmpty)
        #expect(draft.metadata.duration > 230 && draft.metadata.duration <= 240)
        #expect(await prepared.precomputeRecording(draft))
        #expect(world.catalog.llm.calls.get.isEmpty)
        #expect(try await world.library.list().isEmpty)
    }

    @Test func streamingAudioIncludesSilenceAndFinishIsIdempotent() async throws {
        let world = try World()
        let prepared = try pipeline(world)
        let directory = try temporaryDirectory()
        let mic = directory.appending(path: "mic.wav"), remote = directory.appending(path: "remote.wav")
        let silence = WAVAudio(sampleRate: 16_000, samples: Array(repeating: 0, count: 32_000))
        try WAVFormat.write(silence, to: mic)
        try WAVFormat.write(silence, to: remote)
        let session = RecordingSpeakerSession()
        let processor = LiveRecordingProcessor(pipeline: prepared, session: session, scratch: directory.appending(path: "spans"))
        await processor.append(mic: mic, remote: remote, range: 0..<16_000)
        await processor.append(mic: mic, remote: remote, range: 16_000..<32_000)
        #expect(await processor.progress(transcribedSeconds: 2).diarizedSeconds == 2,
                "model progress advances without requiring an LLM checkpoint")
        await processor.finish()
        await processor.finish()
        #expect(await session.counts == [.me: 32_000, .remote: 32_000])
        #expect(await session.finals == 1)
        #expect(await processor.progress(transcribedSeconds: 2).diarizedSeconds == 2)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "spans").path))
    }

    @Test func aMissingAudioPieceDisablesReuseInsteadOfSilentlyShiftingSpeakers() async throws {
        let world = try World()
        let directory = try temporaryDirectory()
        let session = RecordingSpeakerSession()
        let processor = LiveRecordingProcessor(pipeline: try pipeline(world), session: session, scratch: directory)
        await processor.append(mic: directory.appending(path: "missing.wav"), remote: directory.appending(path: "missing.wav"),
                               range: 16_000..<32_000)
        #expect(await processor.progress(transcribedSeconds: 2).recordingProcessingEnabled == false)
        #expect(await session.counts.isEmpty)
    }

    private enum LiveTestError: Error { case setup }
}
