import Foundation
import MM2TCore
import MM2TSystem
import Testing
@testable import MM2TApp

/// Answers each piece with one word spanning the first second of the file it was given.
struct PieceSTT: TranscriptionProvider {
    let files = Box<[String]>([])
    let fails = Box(false)

    func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) async throws -> TranscribedWords {
        files.update { $0.append(audio.lastPathComponent) }
        if fails.get { throw TranscriptionError.failed("no credit") }
        let seconds = try WAVFormat.read(audio).duration
        return .unlabeled([TimedWord(String(format: "%.0fs", seconds), 0, 1)])
    }
}

private struct HeldPieceSTT: TranscriptionProvider {
    let started = Gate<Bool>()
    let release = Gate<Bool>()
    let pieces = PieceSTT()

    func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) async throws -> TranscribedWords {
        await started.open(true)
        _ = await release.wait()
        return try await pieces.transcribe(audio: audio, hints: hints, labelSpeakers: labelSpeakers)
    }
}

private actor ConfigurationSpeakerSession: StreamingDiarizationSession {
    let holdsAppend: Bool
    let holdsSnapshot: Bool
    let appendStarted = Gate<Bool>()
    let releaseAppend = Gate<Bool>()
    let snapshotStarted = Gate<Bool>()
    let releaseSnapshot = Gate<Bool>()
    private(set) var snapshots: [Bool] = []
    private(set) var frames: [Track: Int] = [:]

    init(holdsAppend: Bool = false, holdsSnapshot: Bool = false) {
        self.holdsAppend = holdsAppend
        self.holdsSnapshot = holdsSnapshot
    }

    func append(samples: [Float], track: Track) async {
        if holdsAppend {
            await appendStarted.open(true)
            _ = await releaseAppend.wait()
        }
        frames[track, default: 0] += samples.count
    }

    func snapshot(tracks: [Track: URL], final: Bool) async -> StreamingDiarizationSnapshot {
        snapshots.append(final)
        if holdsSnapshot {
            await snapshotStarted.open(true)
            _ = await releaseSnapshot.wait()
        }
        return StreamingDiarizationSnapshot(diarizations: [.me: Script.diarization, .remote: Script.diarization],
                                            processedSeconds: frames.mapValues { Double($0) / 16_000 })
    }
}

@Suite struct LiveTranscriptionTests {
    static let rate = 1000

    @Test func recordingUsesHostedRoutesWithoutSkippingOverALocalPreference() async throws {
        let hosted = FakeSTT(.unreachable), cloud = FakeSTT(.unreachable), local = FakeSTT()
        let full = TranscriptionChain([.init(.selfHosted, hosted), .init(.cloud, cloud), .init(.local, local)])
        let live = try #require(LiveTranscriber.recordingChain(full))
        #expect(live.routes.map(\.source) == [.selfHosted, .cloud])
        let files = try recording(mic: Self.tone(1), remote: Self.tone(1))
        #expect((try? await live.transcribe(audio: files.mic, hints: [], labelSpeakers: false)) == nil)
        #expect(local.calls.get.isEmpty, "the recording never starts the on-device fallback")
        #expect(try await full.transcribe(audio: files.mic, hints: [], labelSpeakers: true).source == .local)

        #expect(LiveTranscriber.recordingChain(TranscriptionChain([.init(.local, local), .init(.cloud, cloud)])) == nil)
        let prioritized = try #require(LiveTranscriber.recordingChain(
            TranscriptionChain([.init(.selfHosted, hosted), .init(.local, local), .init(.cloud, cloud)])))
        #expect(prioritized.routes.map(\.source) == [.selfHosted], "do not skip a local preference to use a lower-priority cloud source")
        #expect(LiveTranscriber.recordingChain(TranscriptionChain([])) == nil)
    }

    /// `seconds` of a loud tone with a silent half-second ending at each of `quietEnds`.
    static func tone(_ seconds: Int, quietEnds: [Double] = []) -> [Int16] {
        (0..<seconds * rate).map { frame in
            let time = Double(frame) / Double(rate)
            if quietEnds.contains(where: { time >= $0 - 0.5 && time < $0 }) { return 0 }
            return frame % 2 == 0 ? 8000 : -8000
        }
    }

    func recording(mic: [Int16], remote: [Int16]) throws -> (directory: URL, mic: URL, remote: URL) {
        let directory = try temporaryDirectory()
        let micURL = directory.appending(path: "mic.wav"), remoteURL = directory.appending(path: "remote.wav")
        try WAVFormat.write(WAVAudio(sampleRate: Self.rate, samples: mic), to: micURL)
        try WAVFormat.write(WAVAudio(sampleRate: Self.rate, samples: remote), to: remoteURL)
        return (directory, micURL, remoteURL)
    }

    func transcriber(_ files: (directory: URL, mic: URL, remote: URL), _ stt: PieceSTT,
                     now: @escaping @Sendable () -> Date = Date.init) -> LiveTranscriber {
        LiveTranscriber(mic: files.mic, remote: files.remote, chain: TranscriptionChain([.init(.cloud, stt)]),
                        hints: [], scratch: files.directory.appending(path: "scratch"), pieceSeconds: 20, now: now)
    }

    @Test func piecesAreCutAtQuietPlacesAndTimedFromTheStart() async throws {
        let files = try recording(mic: Self.tone(50, quietEnds: [17, 33]), remote: [Int16](repeating: 0, count: 50 * Self.rate))
        let stt = PieceSTT()
        let live = transcriber(files, stt)

        await live.advance()
        #expect(abs(await live.transcribedSeconds - 32.65) < 0.01, "two pieces, each ended in the quiet half-second")
        let transcription = try #require(await live.finish(mic: files.mic, remote: files.remote))

        let starts = transcription.me.words.map(\.range.start)
        #expect(starts.count == 3)
        #expect(abs(starts[1] - 16.65) < 0.01 && abs(starts[2] - 32.65) < 0.01)
        #expect(transcription.remote.words.isEmpty)
        #expect(stt.files.get.allSatisfy { $0.hasPrefix("me-") }, "a silent track is never uploaded")
        #expect(!FileManager.default.fileExists(atPath: files.directory.appending(path: "scratch").path))
    }

    @Test func aRecordingShorterThanAPieceIsTranscribedWholeAtTheEnd() async throws {
        let files = try recording(mic: Self.tone(8), remote: Self.tone(8))
        let stt = PieceSTT()
        let live = transcriber(files, stt)

        await live.advance()
        #expect(stt.files.get.isEmpty)
        let transcription = try #require(await live.finish(mic: files.mic, remote: files.remote))
        #expect(transcription.me.words.map(\.text) == ["8s"])
        #expect(transcription.remote.words.map(\.text) == ["8s"])
    }

    @Test func aPieceOfTheMicThatOnlyHeardTheSpeakersHasNoWords() async throws {
        var state: UInt64 = 7
        let played = (0..<8 * Self.rate).map { _ -> Int16 in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int16(truncatingIfNeeded: Int(state >> 48) - 32768) / 2
        }
        let heard = (0..<played.count).map { $0 >= 30 ? played[$0 - 30] / 3 : 0 }
        let files = try recording(mic: heard, remote: played)
        let transcription = try #require(await transcriber(files, PieceSTT()).finish(mic: files.mic, remote: files.remote))

        #expect(transcription.me.words.isEmpty)
        #expect(transcription.remote.words.map(\.text) == ["8s"])
    }

    @Test func aFailedPieceMeansNoLiveTranscription() async throws {
        let files = try recording(mic: Self.tone(30), remote: Self.tone(30))
        let stt = PieceSTT()
        stt.fails.set(true)
        let live = transcriber(files, stt)

        await live.advance()
        #expect(await live.finish(mic: files.mic, remote: files.remote) == nil)
    }

    @Test func aTemporaryFailureRetriesOnlyTheUnfinishedAudio() async throws {
        let files = try recording(mic: Self.tone(20, quietEnds: [17]), remote: [Int16](repeating: 0, count: 20 * Self.rate))
        let stt = PieceSTT()
        let clock = Box(Date(timeIntervalSince1970: 0))
        let live = transcriber(files, stt, now: { clock.get })
        await live.advance()
        let completed = await live.transcribedSeconds
        #expect(completed > 0)

        try WAVFormat.write(WAVAudio(sampleRate: Self.rate, samples: Self.tone(50, quietEnds: [17, 33])), to: files.mic)
        try WAVFormat.write(WAVAudio(sampleRate: Self.rate, samples: [Int16](repeating: 0, count: 50 * Self.rate)), to: files.remote)
        stt.fails.set(true)
        await live.advance()
        #expect(await live.transcribedSeconds == completed)

        stt.fails.set(false)
        let attempts = stt.files.get.count
        await live.advance()
        #expect(stt.files.get.count == attempts, "a transient failure backs off instead of retrying every poll")
        clock.update { $0 += 30 }
        await live.advance()
        #expect(await live.transcribedSeconds > completed, "recording resumes transcription without waiting for stop")
        let result = try #require(await live.finish(mic: files.mic, remote: files.remote))
        #expect(stt.files.get.filter { $0 == "me-0.wav" }.count == 1, "successful audio is never uploaded again")
        #expect(result.me.words.count == 3)
        #expect(result.me.words.map(\.range.start) == result.me.words.map(\.range.start).sorted())
        #expect(await live.transcribedSeconds == 50)
    }

    @Test func repeatedFailuresBackOffWhileRecording() async throws {
        let files = try recording(mic: Self.tone(20), remote: [Int16](repeating: 0, count: 20 * Self.rate))
        let stt = PieceSTT()
        stt.fails.set(true)
        let clock = Box(Date(timeIntervalSince1970: 0))
        let live = transcriber(files, stt, now: { clock.get })
        for (seconds, attempts) in [(0.0, 1), (29, 1), (30, 2), (89, 2), (90, 3), (209, 3), (210, 4)] {
            clock.set(Date(timeIntervalSince1970: seconds))
            await live.advance()
            #expect(stt.files.get.count == attempts)
        }
        stt.fails.set(false)
        #expect(await live.finish(mic: files.mic, remote: files.remote) != nil, "stop bypasses the remaining backoff")
    }

    @Test func movingTheRecordingWaitsForTheActivePieceAndKeepsItsWords() async throws {
        let files = try recording(mic: Self.tone(50, quietEnds: [17, 33]), remote: [Int16](repeating: 0, count: 50 * Self.rate))
        let stt = HeldPieceSTT()
        let live = LiveTranscriber(mic: files.mic, remote: files.remote, chain: TranscriptionChain([.init(.cloud, stt)]),
                                   hints: [], scratch: files.directory.appending(path: "scratch"), pieceSeconds: 20)
        let advancing = Task { await live.advance() }
        _ = await stt.started.wait()
        advancing.cancel() // Stopping cancels the polling task, but must keep its active upload.
        let library = MeetingLibrary(root: files.directory.appending(path: "library"))
        let moved = Box(false)
        let moving = Task {
            await live.prepareForMove()
            let meeting = try await library.create(Recording(micTrack: files.mic, remoteTrack: files.remote, highlights: [],
                metadata: MeetingMetadata(title: "Recording", startedAt: Date(), duration: 50)))
            moved.set(true)
            return await live.finish(mic: library.audioURL(meeting, track: .me), remote: library.audioURL(meeting, track: .remote))
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!moved.get)
        #expect(FileManager.default.fileExists(atPath: files.mic.path))
        await stt.release.open(true)
        await advancing.value
        let result = try #require(try await moving.value)
        #expect(result.me.words.count == 3)
        #expect(stt.pieces.files.get.filter { $0 == "me-0.wav" }.count == 1)
        #expect(await live.transcribedSeconds == 50)
    }

    @MainActor @Test(arguments: [false, true])
    func stoppingDuringAnUploadOrAppendKeepsTheTailWithoutStartingACheckpoint(holdAppend: Bool) async throws {
        let files = try configurationRecording()
        let world = try World()
        let stt = HeldPieceSTT()
        let session = ConfigurationSpeakerSession(holdsAppend: holdAppend)
        let processor = try configurationProcessor(world, session: session, directory: files.directory)
        let live = LiveTranscriber(mic: files.mic, remote: files.remote, chain: TranscriptionChain([.init(.cloud, stt)]),
                                   hints: [], scratch: files.directory.appending(path: "scratch"), pieceSeconds: 40,
                                   processing: processor)
        if holdAppend { await stt.release.open(true) }
        let advancing = Task { await live.advance() }
        if holdAppend { _ = await session.appendStarted.wait() }
        else { _ = await stt.started.wait() }
        let returned = Box(false)
        let preparing = Task { await live.prepareForMove(); returned.set(true) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!returned.get, "the active piece must finish before its files can move")
        await stt.release.open(true)
        await session.releaseAppend.open(true)
        await advancing.value
        await preparing.value
        #expect(await session.snapshots.isEmpty, "stopping skips the otherwise eligible recording checkpoint")
        #expect(world.catalog.llm.calls.get.isEmpty)
        #expect(await processor.progress(transcribedSeconds: 0).recordingProcessingEnabled,
                "quiescing checkpoints must not discard audio-derived results")

        let transcription = try #require(await live.finish(mic: files.mic, remote: files.remote))
        #expect(transcription.me.words.count == 3 && transcription.remote.words.isEmpty)
        #expect(stt.pieces.files.get.count == 3 && Set(stt.pieces.files.get).count == 3)
        #expect(await session.frames == [.me: 80 * 16_000, .remote: 80 * 16_000])
        #expect(await session.snapshots == [true], "only the complete final audio should be snapshotted")
        #expect(await live.transcribedSeconds == 80)
        #expect(world.catalog.llm.calls.get.isEmpty)
    }

    @Test func changingConfigurationStopsNewPiecesAndPermanentlyInvalidatesTheSession() async throws {
        let files = try recording(mic: Self.tone(20, quietEnds: [17]), remote: Array(repeating: 0, count: 20 * Self.rate))
        let stt = PieceSTT()
        let current = Box(true)
        let scratch = files.directory.appending(path: "scratch")
        let live = LiveTranscriber(mic: files.mic, remote: files.remote, chain: TranscriptionChain([.init(.cloud, stt)]),
                                   hints: [], scratch: scratch, pieceSeconds: 20, configurationIsCurrent: { current.get })
        await live.advance()
        #expect(stt.files.get.count == 1)
        let completed = await live.transcribedSeconds
        #expect(completed > 0)
        #expect(FileManager.default.fileExists(atPath: scratch.path))

        current.set(false)
        try WAVFormat.write(WAVAudio(sampleRate: Self.rate, samples: Self.tone(50, quietEnds: [17, 33])), to: files.mic)
        try WAVFormat.write(WAVAudio(sampleRate: Self.rate, samples: Array(repeating: 0, count: 50 * Self.rate)), to: files.remote)
        await live.advance()
        #expect(stt.files.get.count == 1, "new audio must not use the old provider after settings change")
        #expect(await live.transcribedSeconds == completed)
        #expect(await live.isConfigurationCurrent() == false)

        current.set(true)
        await live.advance()
        #expect(await live.isConfigurationCurrent() == false, "returning to the former settings cannot resurrect invalidated work")
        #expect(stt.files.get.count == 1)
        #expect(await live.finish(mic: files.mic, remote: files.remote) == nil)
        #expect(stt.files.get.count == 1, "finish delegates to the ordinary pipeline instead of uploading a stale tail")
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
    }

    @MainActor @Test func changingConfigurationDuringAnUploadStartsNoNextPieceOrCheckpoint() async throws {
        let files = try configurationRecording()
        let world = try World()
        let session = ConfigurationSpeakerSession()
        let processor = try configurationProcessor(world, session: session, directory: files.directory)
        let current = Box(true)
        let stt = HeldPieceSTT()
        let scratch = files.directory.appending(path: "scratch")
        let live = LiveTranscriber(mic: files.mic, remote: files.remote, chain: TranscriptionChain([.init(.cloud, stt)]),
                                   hints: [], scratch: scratch, pieceSeconds: 40, processing: processor,
                                   configurationIsCurrent: { current.get })
        let advancing = Task { await live.advance() }
        _ = await stt.started.wait()
        current.set(false)
        await stt.release.open(true)
        await advancing.value

        #expect(stt.pieces.files.get.count == 1, "the request already sent may finish, but queued audio must not upload")
        #expect(await session.snapshots.isEmpty, "the completed request must not initiate a stale speaker/LLM checkpoint")
        #expect(world.catalog.llm.calls.get.isEmpty)
        #expect(await live.isConfigurationCurrent() == false)
        current.set(true)
        await live.advance()
        #expect(stt.pieces.files.get.count == 1)
        #expect(await live.finish(mic: files.mic, remote: files.remote) == nil)
        #expect(await session.snapshots.isEmpty, "invalidated finish must not finalize the stale speaker session")
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
    }

    @MainActor @Test func changingConfigurationDuringSpeakerPreparationStartsNoCheckpoint() async throws {
        let files = try configurationRecording()
        let world = try World()
        let session = ConfigurationSpeakerSession(holdsAppend: true)
        let processor = try configurationProcessor(world, session: session, directory: files.directory)
        let current = Box(true)
        let stt = PieceSTT()
        let live = LiveTranscriber(mic: files.mic, remote: files.remote, chain: TranscriptionChain([.init(.cloud, stt)]),
                                   hints: [], scratch: files.directory.appending(path: "scratch"), pieceSeconds: 40,
                                   processing: processor, configurationIsCurrent: { current.get })
        let advancing = Task { await live.advance() }
        _ = await session.appendStarted.wait()
        current.set(false)
        await session.releaseAppend.open(true)
        await advancing.value

        #expect(stt.files.get.count == 1)
        #expect(await session.snapshots.isEmpty, "settings must be checked again after awaiting local speaker work")
        #expect(world.catalog.llm.calls.get.isEmpty)
        #expect(await live.finish(mic: files.mic, remote: files.remote) == nil)
    }

    @Test func changingConfigurationDuringTheFinalUploadDiscardsItsResultAndScratch() async throws {
        let files = try recording(mic: Self.tone(8), remote: Array(repeating: 0, count: 8 * Self.rate))
        let current = Box(true)
        let stt = HeldPieceSTT()
        let scratch = files.directory.appending(path: "scratch")
        let live = LiveTranscriber(mic: files.mic, remote: files.remote, chain: TranscriptionChain([.init(.cloud, stt)]),
                                   hints: [], scratch: scratch, pieceSeconds: 20, configurationIsCurrent: { current.get })
        let finishing = Task { await live.finish(mic: files.mic, remote: files.remote) }
        _ = await stt.started.wait()
        #expect(FileManager.default.fileExists(atPath: scratch.path))
        current.set(false)
        await stt.release.open(true)

        #expect(await finishing.value == nil, "even a final piece that completed successfully cannot reuse stale settings")
        #expect(stt.pieces.files.get.count == 1)
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        current.set(true)
        #expect(await live.isConfigurationCurrent() == false)
    }

    @MainActor @Test func changingConfigurationDuringASpeakerSnapshotNeverStartsSpeculativeLLMWork() async throws {
        let files = try configurationRecording()
        let world = try World()
        let current = Box(true)
        let session = ConfigurationSpeakerSession(holdsSnapshot: true)
        let processor = try configurationProcessor(world, session: session, directory: files.directory,
                                                   configurationIsCurrent: { current.get })
        await processor.append(mic: files.mic, remote: files.remote, range: 0..<(32 * 16_000))
        let transcript = Transcription(me: TrackTranscript(source: .cloud, content: .unlabeled([TimedWord("完成進度", 0, 1)])),
                                       remote: TrackTranscript(source: .cloud, content: .unlabeled([])))
        let manifest = try RecordingManifest.read(from: files.directory)
        let checkpoint = Task { await processor.checkpoint(transcript, manifest: manifest) }
        _ = await session.snapshotStarted.wait()
        current.set(false)
        await session.releaseSnapshot.open(true)
        await checkpoint.value

        #expect(await session.snapshots == [false], "the snapshot already in progress can finish")
        #expect(world.catalog.llm.calls.get.isEmpty, "returning from speaker inference must recheck settings before sending a new LLM request")
        let progress = await processor.progress(transcribedSeconds: 32)
        #expect(!progress.recordingProcessingEnabled)
        #expect(!progress.checkpointBusy)
        #expect(progress.checkpointSeconds == 0)
        #expect(!FileManager.default.fileExists(atPath: files.directory.appending(path: "spans").path))

        current.set(true)
        await processor.checkpoint(transcript, manifest: manifest)
        #expect(await session.snapshots == [false], "discarded preparation cannot restart when settings are switched back")
        #expect(world.catalog.llm.calls.get.isEmpty)
    }

    private func configurationRecording() throws -> (directory: URL, mic: URL, remote: URL) {
        let directory = try temporaryDirectory()
        let mic = directory.appending(path: "mic.wav"), remote = directory.appending(path: "remote.wav")
        // The real recording processor requires 16 kHz. A 35-second quiet cut crosses its
        // checkpoint threshold, and 80 seconds leaves another complete upload waiting.
        let samples = Self.tone(80, quietEnds: [35, 69]).flatMap { Array(repeating: $0, count: 16) }
        try WAVFormat.write(WAVAudio(sampleRate: 16_000, samples: samples), to: mic)
        try WAVFormat.write(WAVAudio(sampleRate: 16_000, samples: Array(repeating: 0, count: samples.count)), to: remote)
        try RecordingManifest(title: "Recording", startedAt: Date(), platform: nil, targetBundleID: nil).write(to: directory)
        return (directory, mic, remote)
    }

    @MainActor private func configurationProcessor(_ world: World, session: ConfigurationSpeakerSession,
                                                   directory: URL,
                                                   configurationIsCurrent: @escaping @MainActor @Sendable () -> Bool = { true }) throws -> LiveRecordingProcessor {
        let setup = PipelineSetup(library: world.library, voiceprints: world.app.voiceprints,
                                  credentials: world.credentials, catalog: world.catalog)
        guard case .ready(let pipeline) = try setup.build(world.app.settings.settings) else {
            throw ConfigurationTestError.setup
        }
        return LiveRecordingProcessor(pipeline: pipeline, session: session, scratch: directory.appending(path: "spans"),
                                      configurationIsCurrent: configurationIsCurrent)
    }

    private enum ConfigurationTestError: Error { case setup }

    @MainActor @Test func wordsHeardWhileRecordingLetProcessingStartAtSpeakerSeparation() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        let fresh = try await world.library.create(Recording(
            micTrack: try copy(await world.library.audioURL(meeting, track: .me)),
            remoteTrack: try copy(await world.library.audioURL(meeting, track: .remote)),
            highlights: [], metadata: MeetingMetadata(title: "現場", startedAt: Date(), duration: 10)))
        let heard = Transcription(
            me: TrackTranscript(source: .cloud, content: .unlabeled([TimedWord("软件", 0, 1)])),
            remote: TrackTranscript(source: .cloud, content: .unlabeled([])))

        let attached = try await world.library.attach(heard, to: fresh.id)
        #expect(attached.status == .pending(next: .diarize))
        #expect(attached.transcription?.me.words.map(\.text) == ["軟件"])
        #expect(try await world.library.attach(heard, to: meeting.id).status == .completed, "a processed meeting is left alone")
    }

    private func copy(_ url: URL) throws -> URL {
        let target = try temporaryDirectory().appending(path: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }
}
