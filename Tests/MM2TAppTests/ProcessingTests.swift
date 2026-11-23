import Foundation
import MM2TCore
import MM2TProviders
import MM2TSystem
import Testing
@testable import MM2TApp

@MainActor @Suite struct ProcessingTests {
    @Test func rewritingRetainsItsExistingSetupRequirements() async {
        let queue = ProcessingQueue(
            makePipeline: { .needsSetup([.transcriptionServiceNotConfigured(.elevenLabs)]) },
            makeLLM: { throw URLError(.badServerResponse) })
        await #expect(throws: RewriteUnsupported.self) {
            try await queue.rewrite("Original passage", instruction: "Make it concise")
        }
    }

    @Test func missingKeysRouteToSetupBeforeAnyStepRuns() async throws {
        let world = try World(keys: false)
        let meeting = try await world.recordedMeeting()

        #expect(world.queue.jobs[meeting.id] == .needsSetup([.transcriptionServiceNotConfigured(.elevenLabs), .summaryServiceNotConfigured(.gemini)]))
        #expect(world.queue.pendingSetup == [.transcriptionServiceNotConfigured(.elevenLabs), .summaryServiceNotConfigured(.gemini)])
        #expect(world.catalog.providerCalls == 0, "nothing was uploaded")
        #expect(try await world.library.meeting(meeting.id).status == .pending(next: .transcribe), "not a failure")

        world.app.setup.field(.elevenLabsAPIKey).text = "eleven"
        world.app.setup.field(.elevenLabsAPIKey).save()
        world.app.setup.field(.geminiAPIKey).text = "gemini"
        world.app.setup.field(.geminiAPIKey).save()
        world.app.setup.recheck()
        #expect(world.app.setup.issues.isEmpty)

        await world.queue.retryAfterSetup()
        #expect(world.queue.jobs[meeting.id] == .completed)
        #expect(Set(world.catalog.keysUsed.get) == ["stt:eleven", "llm:gemini"], "the saved keys reached the providers")
    }

    @Test func onlySelectedServicesNeedConfigurationAndSpeakerSeparationStaysLocal() throws {
        let world = try World()
        let setup = PipelineSetup(library: world.library, voiceprints: world.app.voiceprints,
                                  credentials: world.credentials, catalog: world.catalog)
        var settings = AppSettings()
        settings.transcriptionService = .server
        settings.summaryService = .openAICompatible
        settings.localCaptionModel = .breeze
        guard case .needsSetup(let issues) = try setup.build(settings) else { Issue.record("Expected setup issues"); return }
        #expect(issues == [.transcriptionServiceNotConfigured(.server), .summaryServiceNotConfigured(.openAICompatible)])
        #expect(issues.compactMap(\.service) == [.transcriptionServer, .openAICompatible])
        world.catalog.modelsDownloaded.set(false)
        guard case .needsSetup(let missing) = try setup.build(AppSettings()) else { Issue.record("Expected speaker models issue"); return }
        #expect(missing == [.diarizationModelsMissing])
    }

    @Test func hostedJobsUseOnlyTheTokenForTheConfiguredCollaborationAPI() throws {
        let world = try World()
        world.catalog.keysUsed.set([])
        let setup = PipelineSetup(library: world.library, voiceprints: world.app.voiceprints,
                                  credentials: world.credentials, catalog: world.catalog)
        let api = URL(string: "https://collab.example/proxy/")!
        #expect(PipelineSetup.hostedURL(api, job: "stt").absoluteString == "https://collab.example/proxy/v1/hosted/stt")
        #expect(PipelineSetup.hostedURL(api, job: "llm").absoluteString == "https://collab.example/proxy/v1/hosted/llm")
        var settings = AppSettings()
        settings.transcriptionService = .mm2t
        settings.summaryService = .mm2t
        let stored = #"{"apiURL":"https://collab.example/proxy/","tokens":{"accessToken":"test-bearer","refreshToken":"test-refresh"}}"#
        try world.credentials.save(Secret(stored), for: .collabAccount)
        guard case .needsSetup(let issues) = try setup.build(settings, accountURL: URL(string: "https://other.example")) else {
            Issue.record("Wrong account origin must not receive the token"); return
        }
        #expect(issues == [.transcriptionServiceNotConfigured(.mm2t), .summaryServiceNotConfigured(.mm2t)])
        guard case .ready(let pipeline) = try setup.build(settings, accountURL: api) else { Issue.record("Expected hosted plan"); return }
        #expect(pipeline.transcription.routes.count == 1)
        #expect(world.catalog.selfHostedURLs.get.map(\.absoluteString) == ["https://collab.example/proxy/v1/hosted/stt"])
        #expect(world.catalog.openAIEndpoints.get == ["https://collab.example/proxy/v1/hosted/llm|test-bearer|mm2t"])
        #expect(world.catalog.keysUsed.get == ["hosted-stt:test-bearer"])
    }

    @Test(arguments: [TranscriptionService.elevenLabs, .server, .mm2t])
    func hostedSummariesDoNotPreventOwnTranscriptionDuringRecording(source: TranscriptionService) async throws {
        let api = URL(string: "https://collab.example")!
        let world = try World(collabConfiguration: .init(apiURL: api, webURL: api))
        try world.credentials.save(Secret(#"{"apiURL":"https://collab.example","tokens":{"accessToken":"plan-token","refreshToken":"refresh"}}"#), for: .collabAccount)
        world.catalog.selfHosted.behavior.set(.words)
        let diarizer = RecordingTestDiarizer()
        world.catalog.recordingDiarizer.set(diarizer)
        world.app.settings.settings.transcriptionService = source
        world.app.settings.settings.summaryService = .mm2t
        world.app.settings.settings.selfHostedURL = URL(string: "https://speech.example")
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "預算會議", platform: .zoom))
        let directory = try #require(world.recorder.last?.configuration.directory)
        let samples = (0..<(16_000 * 65)).map { Int16($0 % 32 < 16 ? 2200 : -2200) }
        try WAVFormat.write(WAVAudio(sampleRate: 16_000, samples: samples), to: directory.appending(path: RecordingManifest.micFile))
        try WAVFormat.write(WAVAudio(sampleRate: 16_000, samples: Array(repeating: 0, count: samples.count)),
                            to: directory.appending(path: RecordingManifest.remoteFile))
        var progress: LiveProcessingProgress?
        let deadline = ContinuousClock.now + .seconds(source == .mm2t ? 3 : 8)
        repeat {
            try await Task.sleep(for: .milliseconds(50))
            progress = await world.capture.liveProgress()
        } while (progress?.diarizedSeconds ?? 0) < 30 && ContinuousClock.now < deadline
        switch source {
        case .elevenLabs:
            #expect(!world.catalog.cloud.calls.get.isEmpty)
            #expect(world.catalog.selfHosted.calls.get.isEmpty)
        case .server:
            #expect(!world.catalog.selfHosted.calls.get.isEmpty)
            #expect(world.catalog.cloud.calls.get.isEmpty)
        case .mm2t:
            #expect(world.catalog.selfHosted.calls.get.isEmpty)
            #expect(progress == nil)
        }
        if source != .mm2t {
            #expect((progress?.transcribedSeconds ?? 0) >= 30)
            #expect((progress?.diarizedSeconds ?? 0) >= 30)
        }
        #expect(await diarizer.session.checkpoints == 0)
        #expect(world.catalog.llm.calls.get.isEmpty)
        await world.capture.stop()
    }

    @Test func speakersAreToldApartOnThisMacEvenWhenOldSettingsPreferredTheServicesLabels() async throws {
        let world = try World()
        let old = Data(#"{"transcriptionOrder":["cloud"],"diarizationOrder":["transcription","local"]}"#.utf8)
        world.defaults.set(old, forKey: SettingsStore.key)
        world.app.settings.settings = SettingsStore(defaults: world.defaults).settings

        let meeting = try await world.recordedMeeting()
        #expect(meeting.status == .completed)
        #expect(meeting.attribution?.source == .local)
        #expect(!world.catalog.cloud.labelRequests.get.isEmpty)
        #expect(!world.catalog.cloud.labelRequests.get.contains(true), "the service is never asked for speaker labels")
    }

    @Test func aFailedTranscriptionServerNeverSendsAudioToElevenLabsOrTheMac() async throws {
        let world = try World()
        let server = try #require(AppSettings.selfHostedURL(from: " http://gpu.tailnet:8000 "))
        world.app.settings.settings.selfHostedURL = server
        world.app.settings.settings.transcriptionService = .server
        world.app.settings.settings.localCaptionModel = .breeze
        world.catalog.offlineDownloaded[.transcription]!.set(true)

        let meeting = try await world.recordedMeeting()
        #expect(Set(world.catalog.selfHostedURLs.get) == [server])
        #expect(!world.catalog.selfHosted.calls.get.isEmpty)
        #expect(world.catalog.cloud.calls.get.isEmpty)
        #expect(world.catalog.onDeviceSTT.calls.get.isEmpty)
        guard case .failed(step: .transcribe, reason: _) = world.queue.jobs[meeting.id] else {
            Issue.record("Expected the server failure to surface"); return
        }
    }

    @Test func aLocalCaptionModelDoesNotSerializeGemini() async throws {
        let world = try World()
        world.catalog.offlineDownloaded[.transcription]!.set(true)
        world.app.settings.settings.localSpeechModel = .breeze
        let gate = Gate<Bool>()
        world.catalog.llm.holds.update { $0["inferNames"] = gate }
        await world.capture.startNow(title: "Concurrent cloud summary")
        let stopping = Task { await world.capture.stop() }
        #expect(await eventually { Set(world.catalog.llm.calls.get) == Set(["inferNames", "cleanTranscript", "digestPerPerson", "summarize"]) },
                "the other hosted LLM tasks finish while name inference is still waiting")
        await gate.open(true)
        await stopping.value
        #expect(try await world.library.list().first?.status == .completed)
    }

    @Test func cancellingAJobLeavesTheMeetingReadyToResumeFromTheStoppedStep() async throws {
        let world = try World()
        let gate = Gate<Bool>()
        world.catalog.llm.holds.update { $0["inferNames"] = gate }
        await world.capture.startNow(title: "Stopped by the user")
        let stopping = Task { await world.capture.stop() }
        #expect(await eventually { world.catalog.llm.calls.get.contains("inferNames") })
        let id = try #require(world.app.queue.activeJob?.id)

        world.app.queue.cancel(id)
        await gate.open(true)
        await stopping.value

        #expect(world.app.queue.jobs[id] == nil)

        #expect(try await world.library.meeting(id).status == .pending(next: .inferNames))

        await world.app.queue.run(.process, on: id)
        #expect(try await world.library.meeting(id).status == .completed)
    }

    @Test func cancellingAQueuedJobTakesItOutOfLineAtOnceAndItNeverRuns() async throws {
        let world = try World()
        let gate = Gate<Bool>()
        world.catalog.llm.holds.update { $0["inferNames"] = gate }
        await world.capture.startNow(title: "Ahead in line")
        let first = Task { await world.capture.stop() }
        #expect(await eventually { world.catalog.llm.calls.get.contains("inferNames") })
        await world.capture.startNow(title: "Waiting in line")
        let second = Task { await world.capture.stop() }
        #expect(await eventually { world.app.queue.jobs.values.contains(.queued) })
        let waiting = try #require(world.app.queue.jobs.first { $0.value == .queued }?.key)

        world.app.queue.cancel(waiting)
        #expect(world.app.queue.jobs[waiting] == nil, "out of line before the job ahead finishes")
        #expect(!world.app.queue.isBusy(waiting))

        await gate.open(true)
        await first.value
        await second.value
        #expect(world.app.queue.jobs[waiting] == nil)
        #expect(try await world.library.meeting(waiting).status == .pending(next: .transcribe), "it never ran")
    }

    @Test func aFailedStepShowsItsReasonKeepsTheAudioAndRetriesFromThatStep() async throws {
        let world = try World()
        world.catalog.llm.failNext.set(["summarize"])
        let meeting = try await world.recordedMeeting()

        #expect(world.queue.jobs[meeting.id] == .failed(step: .summarize, reason: "Gemini 暫時無法服務"))
        let stored = try await world.library.meeting(meeting.id)
        for track in Track.allCases {
            #expect(FileManager.default.fileExists(atPath: await world.library.audioURL(stored, track: track).path),
                    "story 26: a failure never deletes the recording")
        }
        let list = world.app.meetings
        await list.reload()
        #expect(list.rows.first?.status == .failed("Gemini 暫時無法服務"))

        let sttCalls = world.catalog.cloud.calls.get.count
        await world.detail(meeting.id).retry()
        #expect(world.queue.jobs[meeting.id] == .completed)
        #expect(world.catalog.cloud.calls.get.count == sttCalls, "the retry resumes at summarize, no new upload")
    }

    @Test func progressNamesTheStepRunningNow() async throws {
        let world = try World()
        let gate = Gate<Bool>()
        world.catalog.llm.holds.update { $0["cleanTranscript"] = gate }
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "週會", platform: .zoom))
        let stopping = Task { await world.capture.stop() }

        #expect(await eventually { world.queue.activeJob?.state == .running(.summarize) })
        let id = try #require(world.queue.activeJob?.id)
        let detail = world.detail(id)
        await detail.load()
        #expect(!detail.canEditSpeakers, "edits wait until the pipeline is done")

        await gate.open(true)
        await stopping.value
        #expect(world.queue.jobs[id] == .completed)
        await detail.load()
        #expect(detail.canEditSpeakers)
    }

    @Test func aKeychainErrorFailsTheJobInsteadOfCrashing() async throws {
        struct Locked: CredentialStoring {
            struct Denied: Error, CustomStringConvertible { var description: String { "無法存取鑰匙圈" } }
            func read(_ credential: Credential) throws -> Secret? { throw Denied() }
            func save(_ secret: Secret, for credential: Credential) throws { throw Denied() }
        }
        let world = try World()
        let setup = PipelineSetup(library: world.library, voiceprints: world.app.voiceprints, credentials: Locked(), catalog: world.catalog)
        let queue = ProcessingQueue(makePipeline: { try setup.build(AppSettings()) },
                                    makeLLM: { try setup.buildLLM(AppSettings()) })
        let meeting = try await world.library.create(Recording(
            micTrack: try silentTrack(in: world.root, "a.wav"), remoteTrack: try silentTrack(in: world.root, "b.wav"),
            highlights: [], metadata: MeetingMetadata(title: "x", startedAt: Date(), duration: 1)))
        await queue.run(.process, on: meeting.id)
        #expect(queue.jobs[meeting.id] == .failed(step: nil, reason: "無法存取鑰匙圈"))
    }
}

func silentTrack(in directory: URL, _ name: String, seconds: Int = 1) throws -> URL {
    let url = directory.appending(path: name)
    let writer = try WAVWriter(url: url, sampleRate: 16_000)
    writer.appendSilence(frames: 16_000 * seconds)
    try writer.close()
    return url
}

private struct RecordingTestDiarizer: Diarizer, StreamingDiarizerFactory {
    let session = RecordingTestDiarizationSession()
    func diarize(track: URL) async throws -> Diarization { Script.diarization }
    func makeStreamingSession() async throws -> any StreamingDiarizationSession { session }
}

private actor RecordingTestDiarizationSession: StreamingDiarizationSession {
    private var seconds: [Track: TimeInterval] = [:]
    private(set) var checkpoints = 0

    func append(samples: [Float], track: Track) async throws {
        seconds[track, default: 0] += Double(samples.count) / 16_000
    }

    func processedSeconds() async -> [Track: TimeInterval] { seconds }

    func snapshot(tracks: [Track: URL], final: Bool) async throws -> StreamingDiarizationSnapshot {
        if !final { checkpoints += 1 }
        return .init(diarizations: [.me: Script.diarization, .remote: Script.diarization], processedSeconds: seconds)
    }
}
