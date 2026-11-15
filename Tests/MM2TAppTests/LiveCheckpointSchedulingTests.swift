import Foundation
import MM2TCore
import MM2TSystem
import Testing
@testable import MM2TApp

private struct CheckpointLLM: LLMProvider {
    let cleanEnds = Box<[TimeInterval]>([])
    let releaseFirst = Gate<Bool>()
    let holdsFirst: Bool
    let failNext = Box(false)

    func inferNames(_ request: NameInferenceRequest) async throws -> [NameGuess] { [] }
    func cleanTranscript(_ transcript: LLMTranscript) async throws -> CleanedTranscript {
        cleanEnds.update { $0.append(transcript.utterances.map(\.range.end).max() ?? 0) }
        if holdsFirst, cleanEnds.get.count == 1 { _ = await releaseFirst.wait() }
        if failNext.get {
            failNext.set(false)
            throw FakeLLMError()
        }
        return CleanedTranscript(paragraphs: transcript.utterances.map {
            .init(speaker: $0.speaker, text: $0.text, sources: [$0.id])
        })
    }
    func digestPerPerson(_ transcript: LLMTranscript) async throws -> [PersonDigest] { [] }
    func summarize(_ request: SummaryRequest) async throws -> Summary {
        Summary(decisions: [], discussionPoints: [], actionItems: [])
    }
}

private actor CheckpointSpeakerSession: StreamingDiarizationSession {
    private var samples: [Track: Int] = [:]
    private(set) var snapshots: [Bool] = []
    let releaseFirstSnapshot = Gate<Bool>()
    let holdsFirstSnapshot: Bool
    init(holdsFirstSnapshot: Bool = false) { self.holdsFirstSnapshot = holdsFirstSnapshot }
    func append(samples: [Float], track: Track) { self.samples[track, default: 0] += samples.count }
    func snapshot(tracks: [Track: URL], final: Bool) async -> StreamingDiarizationSnapshot {
        snapshots.append(final)
        let seconds = samples.mapValues { Double($0) / 16_000 }
        if holdsFirstSnapshot, snapshots.count == 1 { _ = await releaseFirstSnapshot.wait() }
        let heard = Diarization(segments: [.init(cluster: ClusterID("S1"),
            range: TimeRange(start: 0, end: seconds[.remote] ?? 0))], overlaps: [], embeddings: [:])
        return StreamingDiarizationSnapshot(diarizations: [
            .me: Diarization(segments: [], overlaps: [], embeddings: [:]), .remote: heard],
            processedSeconds: seconds)
    }
}

@MainActor @Suite struct LiveCheckpointSchedulingTests {
    private struct Fixture {
        let processor: LiveRecordingProcessor
        let session: CheckpointSpeakerSession
        let llm: CheckpointLLM
        let mic: URL
        let remote: URL
        let current: Box<Bool>
        let manifest = RecordingManifest(title: "Checkpoint", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                         platform: nil, targetBundleID: nil)

        func append(from start: Int, to end: Int) async {
            await processor.append(mic: mic, remote: remote, range: start * 16_000..<end * 16_000)
        }
        func checkpoint(through seconds: Int, silent: Bool = false) async {
            let words: [TimedWord] = silent ? [] : stride(from: 5, to: seconds, by: 30).map {
                TimedWord("內容 \($0)", Double($0), Double($0 + 2))
            }
            let transcription = Transcription(me: TrackTranscript(source: .cloud, content: .unlabeled([])),
                remote: TrackTranscript(source: .cloud, content: .unlabeled(words)))
            await processor.checkpoint(transcription, manifest: manifest)
        }
        var progress: LiveProcessingProgress { get async { await processor.progress(transcribedSeconds: 120) } }
    }

    private func fixture(holdsFirst: Bool = true, holdsFirstSnapshot: Bool = false) throws -> Fixture {
        let world = try World()
        let setup = PipelineSetup(library: world.library, voiceprints: world.app.voiceprints,
                                  credentials: world.credentials, catalog: world.catalog)
        guard case .ready(let pipeline) = try setup.build(world.app.settings.settings) else { throw TestFailure.setup }
        let directory = try temporaryDirectory()
        let mic = directory.appending(path: "mic.wav"), remote = directory.appending(path: "remote.wav")
        for url in [mic, remote] {
            let writer = try WAVWriter(url: url, sampleRate: 16_000)
            writer.appendSilence(frames: 120 * 16_000)
            try writer.close()
        }
        let llm = CheckpointLLM(holdsFirst: holdsFirst)
        let session = CheckpointSpeakerSession(holdsFirstSnapshot: holdsFirstSnapshot)
        let current = Box(true)
        let processor = LiveRecordingProcessor(pipeline: pipeline.withLLM(llm), session: session,
            scratch: directory.appending(path: "spans"), configurationIsCurrent: { current.get })
        return Fixture(processor: processor, session: session, llm: llm, mic: mic, remote: remote, current: current)
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await condition()
    }

    @Test func aSlowCheckpointCoalescesToLatestPrefixWithoutAnotherAudioAppend() async throws {
        let f = try fixture()
        await f.append(from: 0, to: 60)
        await f.checkpoint(through: 60)
        #expect(await eventually { f.llm.cleanEnds.get == [37] })
        await f.append(from: 60, to: 90)
        await f.checkpoint(through: 90)
        await f.append(from: 90, to: 120)
        await f.checkpoint(through: 120)
        #expect(f.llm.cleanEnds.get == [37], "one active request while newer inputs coalesce")
        #expect(await f.progress.checkpointBusy)
        await f.llm.releaseFirst.open(true)
        #expect(await waitUntil { await !f.progress.checkpointBusy })
        #expect(f.llm.cleanEnds.get == [37, 97], "the obsolete 90-second request is replaced, and no new append is needed")
        #expect(await f.progress.checkpointSeconds == 97)
        #expect(await f.progress.checkpointAudioSeconds == 118.5)
        #expect(await f.session.snapshots == [false, false])
        await f.processor.finish()
    }

    @Test func finishDiscardsPendingWorkWithoutWaitingForActiveLLM() async throws {
        let f = try fixture()
        await f.append(from: 0, to: 60)
        await f.checkpoint(through: 60)
        #expect(await eventually { f.llm.cleanEnds.get.count == 1 })
        await f.append(from: 60, to: 120)
        await f.checkpoint(through: 120)
        let returned = Box(false)
        let finish = Task { await f.processor.finish(); returned.set(true) }
        #expect(await eventually { returned.get }, "finishing audio must not wait on speculative LLM output")
        await f.llm.releaseFirst.open(true)
        await finish.value
        #expect(await waitUntil { await !f.progress.checkpointBusy })
        await f.checkpoint(through: 120)
        #expect(f.llm.cleanEnds.get == [37])
        #expect(await f.session.snapshots == [false, true])
    }

    @Test func stoppingCheckpointsClearsPendingWorkButKeepsAudioAppendAndTheActiveLLM() async throws {
        let f = try fixture()
        await f.append(from: 0, to: 60)
        await f.checkpoint(through: 60)
        #expect(await eventually { f.llm.cleanEnds.get == [37] })
        await f.append(from: 60, to: 90)
        await f.checkpoint(through: 90)
        let returned = Box(false)
        let stopped = Task { await f.processor.stopCheckpoints(); returned.set(true) }
        #expect(await eventually { returned.get }, "quiescing must not wait for the held LLM request")
        await stopped.value
        #expect(await f.progress.recordingProcessingEnabled)
        #expect(await f.progress.checkpointBusy, "the existing request remains active")
        await f.append(from: 90, to: 120)
        await f.checkpoint(through: 120)
        await f.llm.releaseFirst.open(true)
        #expect(await waitUntil { await !f.progress.checkpointBusy })
        #expect(f.llm.cleanEnds.get == [37], "neither the pending nor newly offered checkpoint can start")
        #expect(await f.progress.checkpointSeconds == 37, "the active request can still warm the cache")
        #expect(await f.session.snapshots == [false])
        await f.processor.finish()
        #expect(await f.session.snapshots == [false, true])
        #expect(await f.progress.diarizedSeconds == 120, "tail appends remain available after checkpoints stop")
        #expect(await f.progress.recordingProcessingEnabled)
    }

    @Test func stoppingDuringASnapshotPreventsItsLLMAndPendingCheckpoint() async throws {
        let f = try fixture(holdsFirst: false, holdsFirstSnapshot: true)
        await f.append(from: 0, to: 60)
        let first = Task { await f.checkpoint(through: 60) }
        #expect(await waitUntil { await f.session.snapshots == [false] })
        await f.append(from: 60, to: 90)
        await f.checkpoint(through: 90)
        await f.processor.stopCheckpoints()
        await f.append(from: 90, to: 120)
        await f.session.releaseFirstSnapshot.open(true)
        await first.value
        #expect(f.llm.cleanEnds.get.isEmpty)
        #expect(await f.session.snapshots == [false])
        #expect(await !f.progress.checkpointBusy)
        #expect(await f.progress.recordingProcessingEnabled)
        await f.processor.finish()
        #expect(await f.session.snapshots == [false, true])
        #expect(await f.progress.diarizedSeconds == 120)
    }

    @Test func inputArrivingDuringSpeakerSnapshotAlsoCoalesces() async throws {
        let f = try fixture(holdsFirst: false, holdsFirstSnapshot: true)
        await f.append(from: 0, to: 60)
        let first = Task { await f.checkpoint(through: 60) }
        #expect(await waitUntil { await f.session.snapshots == [false] })
        await f.append(from: 60, to: 90)
        await f.checkpoint(through: 90)
        await f.append(from: 90, to: 120)
        await f.checkpoint(through: 120)
        #expect(await f.session.snapshots == [false], "actor reentrancy cannot start a second snapshot")
        #expect(f.llm.cleanEnds.get.isEmpty)
        await f.session.releaseFirstSnapshot.open(true)
        await first.value
        #expect(await waitUntil { await !f.progress.checkpointBusy })
        #expect(f.llm.cleanEnds.get == [37, 97])
        #expect(await f.session.snapshots == [false, false])
        await f.processor.finish()
    }

    @Test func discardPreventsPendingCheckpointFromStarting() async throws {
        let f = try fixture()
        await f.append(from: 0, to: 60)
        await f.checkpoint(through: 60)
        #expect(await eventually { f.llm.cleanEnds.get.count == 1 })
        await f.append(from: 60, to: 120)
        await f.checkpoint(through: 120)
        await f.processor.discard()
        await f.llm.releaseFirst.open(true)
        #expect(await waitUntil { await !f.progress.checkpointBusy })
        #expect(f.llm.cleanEnds.get == [37])
        #expect(await f.session.snapshots == [false])
        #expect(await !f.progress.recordingProcessingEnabled)
    }

    @Test func changedSettingsPreventPendingLLMRequest() async throws {
        let f = try fixture()
        await f.append(from: 0, to: 60)
        await f.checkpoint(through: 60)
        #expect(await eventually { f.llm.cleanEnds.get.count == 1 })
        await f.append(from: 60, to: 120)
        await f.checkpoint(through: 120)
        f.current.set(false)
        await f.llm.releaseFirst.open(true)
        #expect(await waitUntil { await !f.progress.checkpointBusy })
        #expect(f.llm.cleanEnds.get == [37])
        #expect(await !f.progress.recordingProcessingEnabled)
    }

    @Test func aFailedRequestCanRetryTheSameInputWatermark() async throws {
        let f = try fixture(holdsFirst: false)
        f.llm.failNext.set(true)
        await f.append(from: 0, to: 60)
        await f.checkpoint(through: 60)
        #expect(await waitUntil { await !f.progress.checkpointBusy })
        #expect(await f.progress.checkpointAudioSeconds == 0)
        await f.checkpoint(through: 60)
        #expect(await waitUntil { await !f.progress.checkpointBusy })
        #expect(f.llm.cleanEnds.get == [37, 37])
        #expect(await f.progress.checkpointAudioSeconds == 58.5)
        await f.processor.finish()
    }

    @Test func confirmedSilenceAdvancesAudioCoverageWithoutCallingLLM() async throws {
        let f = try fixture(holdsFirst: false)
        await f.append(from: 0, to: 60)
        await f.checkpoint(through: 60, silent: true)
        #expect(await waitUntil { await !f.progress.checkpointBusy })
        #expect(f.llm.cleanEnds.get.isEmpty)
        #expect(await f.progress.checkpointSeconds == 0)
        #expect(await f.progress.checkpointAudioSeconds == 58.5)
        await f.processor.finish()
    }

    private enum TestFailure: Error { case setup }
}
