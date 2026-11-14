import Foundation
import MM2TCore
import MM2TProviders
import MM2TSystem
import Testing
@testable import MM2TApp

@MainActor @Suite struct ProcessingTests {
    @Test func rewritingRetainsItsExistingSetupRequirements() async {
        let queue = ProcessingQueue(
            makePipeline: { .needsSetup([.noTranscriptionSource]) },
            makeLLM: { throw URLError(.badServerResponse) })
        await #expect(throws: RewriteUnsupported.self) {
            try await queue.rewrite("Original passage", instruction: "Make it concise")
        }
    }

    @Test func missingKeysRouteToSetupBeforeAnyStepRuns() async throws {
        let world = try World(keys: false)
        let meeting = try await world.recordedMeeting()

        #expect(world.queue.jobs[meeting.id] == .needsSetup([.missingCredential(.elevenLabsAPIKey), .missingCredential(.geminiAPIKey)]))
        #expect(world.queue.pendingSetup == [.missingCredential(.elevenLabsAPIKey), .missingCredential(.geminiAPIKey)])
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

    @Test func eachEnabledSourceMustBeConfiguredIncludingTheOfflineModels() throws {
        let world = try World()
        let setup = PipelineSetup(library: world.library, voiceprints: world.app.voiceprints,
                                  credentials: world.credentials, catalog: world.catalog)
        func issues(_ change: (inout AppSettings) -> Void) throws -> [SetupIssue] {
            var settings = AppSettings()
            change(&settings)
            if case .needsSetup(let issues) = try setup.build(settings) { return issues }
            return []
        }

        #expect(try issues { _ in }.isEmpty)
        #expect(try issues { $0.transcriptionOrder = [.selfHosted, .cloud] } == [.missingSelfHostedURL])
        #expect(try issues { $0.transcriptionOrder = [] } == [.noTranscriptionSource])
        #expect(try issues { $0.transcriptionOrder = [.cloud, .local] } == [.offlineModelMissing(.transcription)])
        #expect(try issues { $0.llmLocation = .local } == [.offlineModelMissing(.llm)])
        world.catalog.offlineDownloaded[.transcription]!.set(true)
        world.catalog.offlineDownloaded[.llm]!.set(true)
        #expect(try issues { $0.transcriptionOrder = [.cloud, .local]; $0.llmLocation = .local }.isEmpty)

        world.catalog.modelsDownloaded.set(false)
        #expect(try issues { _ in } == [.diarizationModelsMissing])
        #expect(try issues { $0.diarizationOrder = [.transcription] }.isEmpty, "STT labels need no local model")
    }

    @Test func transcriptionFollowsTheConfiguredOrderAndFallsThroughWhenSelfHostedIsDown() async throws {
        let world = try World()
        let server = try #require(AppSettings.selfHostedURL(from: " http://gpu.tailnet:8000 "))
        world.app.settings.settings.selfHostedURL = server
        world.app.settings.settings.transcriptionOrder = [.selfHosted, .cloud]
        world.app.settings.settings.addVocabulary("mm2t, Typeless\nmm2t\n", source: .manual)

        let meeting = try await world.recordedMeeting()
        let processed = try await world.library.meeting(meeting.id)

        #expect(Set(world.catalog.selfHostedURLs.get) == [server])
        #expect(world.catalog.selfHosted.calls.get.count == 2, "tried first for both tracks")
        #expect(processed.transcription?.remote.source == .cloud, "story 64: the source actually used is recorded")
        #expect(world.catalog.cloud.calls.get.first?.hints == ["mm2t", "Typeless"])
    }

    @Test func aLocalSpeechFallbackDoesNotSerializeTheCloudLLM() async throws {
        let world = try World()
        world.catalog.offlineDownloaded[.transcription]!.set(true)
        world.app.settings.settings.transcriptionOrder = [.cloud, .local]
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

    @Test func hostedSpeechStillKeepsTheOnDeviceLLMSerial() async throws {
        let world = try World()
        world.catalog.offlineDownloaded[.llm]!.set(true)
        world.app.settings.settings.llmLocation = .local
        let gate = Gate<Bool>()
        world.catalog.onDeviceLLM.holds.update { $0["inferNames"] = gate }
        await world.capture.startNow(title: "Serial local summary")
        let stopping = Task { await world.capture.stop() }
        #expect(await eventually { world.catalog.onDeviceLLM.calls.get.contains("inferNames") })
        try await Task.sleep(for: .milliseconds(20))
        #expect(world.catalog.onDeviceLLM.calls.get == ["inferNames"])
        await gate.open(true)
        await stopping.value
        #expect(world.catalog.onDeviceLLM.calls.get == ["inferNames", "cleanTranscript", "digestPerPerson", "summarize"])
    }

    @Test func speechAndLLMConcurrencyFollowTheirOwnModelLocations() throws {
        let world = try World()
        world.catalog.offlineDownloaded[.transcription]!.set(true)
        world.catalog.offlineDownloaded[.llm]!.set(true)
        let setup = PipelineSetup(library: world.library, voiceprints: world.app.voiceprints,
                                  credentials: world.credentials, catalog: world.catalog)
        for (speech, llm, concurrentSpeech, concurrentLLM) in [
            ([TranscriptionSource.cloud, .local], LLMLocation.cloud, false, true),
            ([.local, .cloud], .cloud, false, true),
            ([.cloud], .local, true, false),
            ([.local], .local, false, false),
        ] {
            var settings = AppSettings()
            settings.transcriptionOrder = speech
            settings.llmLocation = llm
            guard case .ready(let pipeline) = try setup.build(settings) else {
                Issue.record("expected configured pipeline")
                continue
            }
            #expect(pipeline.transcribesConcurrently == concurrentSpeech)
            #expect(pipeline.runsConcurrently == concurrentLLM)
        }
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
