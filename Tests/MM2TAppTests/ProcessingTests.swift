import Foundation
import MM2TCore
import MM2TProviders
import MM2TSystem
import Testing
@testable import MM2TApp

@MainActor @Suite struct ProcessingTests {
    @Test(arguments: [false, true], [false, true])
    func batchTranscriptionSkipsOnlyDigitalSilence(concurrent: Bool, audibleRemote: Bool) async throws {
        let world = try World()
        let stt = world.catalog.cloud
        let micURL = world.root.appending(path: "mic.wav")
        let remoteURL = world.root.appending(path: "remote.wav")
        try WAVFormat.write(WAVAudio(sampleRate: 16_000, samples: [500]), to: micURL)
        var samples = [Int16](repeating: 0, count: 40_000)
        if audibleRemote { samples[samples.count - 1] = 1 }
        try WAVFormat.write(WAVAudio(sampleRate: 16_000, samples: samples), to: remoteURL)
        let meeting = try await world.library.create(Recording(micTrack: micURL, remoteTrack: remoteURL,
            highlights: [], metadata: MeetingMetadata(title: "Track selection", startedAt: Date(), duration: 2.5)))
        let pipeline = MeetingProcessingPipeline(library: world.library, voiceprints: world.app.voiceprints,
            diarizer: nil, embedder: nil, diarizationOrder: [.transcription],
            transcription: TranscriptionChain([.init(.cloud, stt)]), llm: nil,
            thresholds: world.catalog.thresholds, vocabulary: [], transcribesConcurrently: concurrent,
            isSilentTrack: WAVFormat.isDigitalSilence)

        let processed = try await pipeline.process(meeting.id)
        #expect(stt.calls.get.map(\.file).sorted() == (audibleRemote ? ["mic.wav", "remote.wav"] : ["mic.wav"]))
        #expect(stt.labelRequests.get == (audibleRemote ? [true, concurrent] : [true]))
        let transcription = try #require(processed.transcription)
        #expect(!transcription.me.words.isEmpty)
        #expect(transcription.remote.words.isEmpty == !audibleRemote)
    }

    @Test func configuredPipelineDoesNotTranscribeInPersonRemoteTrack() async throws {
        let world = try World()
        world.app.settings.settings.recordingMode = .inPerson
        await world.capture.startNow(title: "In-person")
        await world.capture.stop()
        let meeting = try #require(try await world.library.list().first)
        #expect(world.queue.jobs[meeting.id] == .completed)
        #expect(world.catalog.cloud.calls.get.map(\.file) == ["mic.wav"])
    }

    @Test func rewritingRetainsItsExistingSetupRequirements() async {
        let queue = ProcessingQueue(
            makePipeline: { .needsSetup([.transcriptionServiceNotConfigured(.elevenLabs)]) },
            makeLLM: { throw URLError(.badServerResponse) })
        await #expect(throws: RewriteUnsupported.self) {
            try await queue.rewrite("Original passage", instruction: "Make it concise")
        }
    }

    @Test func listProcessingSharesOneGroupAcrossOutputs() async throws {
        let world = try World()
        let meeting = try await world.library.create(Recording(
            micTrack: try silentTrack(in: world.root, "list-mic.wav"), remoteTrack: try silentTrack(in: world.root, "list-remote.wav"),
            highlights: [], metadata: MeetingMetadata(title: "List processing", startedAt: Date(), duration: 1)))
        await world.app.meetings.process(meeting.id)
        #expect(world.queue.jobs[meeting.id] == .completed)
        let requests = world.catalog.llm.requestGroups.get
        #expect(requests.count >= 3)
        let group = try #require(requests.compactMap { $0 }.first)
        #expect(requests.allSatisfy { $0 == group })
    }

    @Test func eachRewriteGetsItsOwnGroup() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        let detail = world.detail(meeting.id)
        let llm = world.catalog.llm
        llm.requestGroups.set([])
        #expect(try await detail.rewrite("passage", instruction: "Shorten") == "Shorten: passage")
        #expect(try await detail.rewrite("passage", instruction: "Expand") == "Expand: passage")
        let groups = llm.requestGroups.get
        #expect(groups.count == 2)
        #expect(groups.compactMap { $0 }.count == 2)
        #expect(Set(groups).count == 2)
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
        guard case .needsSetup(let missing) = try setup.build(world.app.settings.settings) else { Issue.record("Expected speaker models issue"); return }
        #expect(missing == [.diarizationModelsMissing])
    }

    @Test(arguments: [false, true])
    func signedOutMM2TRecordsLocallyAndDefersAI(hasAccountURL: Bool) async throws {
        let api = URL(string: "https://collab.example")!
        let world = try World(keys: false, collabConfiguration: hasAccountURL ? .init(apiURL: api, webURL: api) : nil)
        world.app.settings.settings = AppSettings()
        world.app.settings.settings.localSpeechModel = .breezeCoreML
        world.catalog.offlineDownloaded[.breezeCoreML]?.set(true)
        world.app.setup.recheck()
        #expect(world.app.setup.issues.isEmpty)

        let meeting = try await world.recordedMeeting()
        #expect(meeting.status == .completed)
        #expect(meeting.transcription?.me.source == .local)
        #expect(!meeting.utterances.isEmpty && !meeting.speakers.isEmpty)
        #expect(meeting.outputs.cleaned == nil)
        #expect(meeting.outputs.digests == nil)
        #expect(meeting.outputs.summary == nil)
        #expect(world.catalog.onDeviceSTT.calls.get.count == 2)
        #expect(world.catalog.llm.calls.get.isEmpty)
        #expect(world.catalog.openAIEndpoints.get.isEmpty)
        #expect(meeting.deferredAIStep == .inferNames)
    }

    @Test(arguments: [false, true])
    func accountAvailabilityResumesOnlyDeferredMeetings(restoredAtLaunch: Bool) async throws {
        let api = URL(string: "https://deferred.example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingTokenProbe.self]
        let world = try World(collabConfiguration: .init(apiURL: api, webURL: api),
                              collabSession: URLSession(configuration: configuration))
        let alreadyProcessed = try await world.recordedMeeting(title: "已經完成")
        #expect(alreadyProcessed.deferredAIStep == nil)
        world.catalog.llm.calls.set([])

        world.app.settings.settings = AppSettings()
        world.app.settings.settings.localSpeechModel = .breezeCoreML
        world.catalog.offlineDownloaded[.breezeCoreML]?.set(true)
        var older = try await world.recordedMeeting(title: "較早")
        let newer = try await world.recordedMeeting(title: "較晚")
        older.metadata.startedAt = newer.metadata.startedAt.addingTimeInterval(-60)
        try await world.library.save(older)
        let firstUtterance = try #require(older.utterances.first)
        let edited = try await TranscriptEditing(library: world.library).edit(firstUtterance.id, in: older.id, to: "保留這段人工修正")
        let account = try #require(world.app.collabAccount)
        let gate = Gate<Bool>()
        world.catalog.llm.holds.set(["summarize": gate])

        if restoredAtLaunch {
            try world.credentials.save(Secret(#"{"apiURL":"https://deferred.example.test","tokens":{"accessToken":"new-token","refreshToken":"new-refresh"}}"#), for: .collabAccount)
            account.observeSignIn()
        } else {
            try await account.completeSignIn(code: "fixture", verifier: "fixture")
        }
        let oldestStarted = await eventually {
            world.catalog.llm.calls.get.contains("summarize") && world.queue.jobs[newer.id] == .queued
        }
        #expect(oldestStarted)
        #expect(world.queue.activeJob?.id == older.id)
        await gate.open(true)
        try #require(await eventually { world.catalog.llm.calls.get.filter { $0 == "summarize" }.count == 2 && !world.queue.isBusy(newer.id) })

        let summarized = try await world.library.meeting(older.id)
        #expect(summarized.status == .completed)
        #expect(summarized.deferredAIStep == nil)
        #expect(summarized.outputs.summary != nil)
        #expect(summarized.outputs.cleaned != nil)
        #expect(!summarized.suggestions.items.isEmpty)
        #expect(summarized.utterances == edited.utterances)
        #expect(try await world.library.meeting(newer.id).deferredAIStep == nil)
        #expect(try await world.library.meeting(alreadyProcessed.id) == alreadyProcessed)
        #expect(world.catalog.onDeviceSTT.calls.get.count == 4)
    }

    @Test func manualRegenerationClearsDeferredAIAndPreventsAutomaticOverwrite() async throws {
        let world = try World()
        world.app.settings.settings.summaryService = .mm2t
        let meeting = try await world.recordedMeeting()
        try #require(meeting.deferredAIStep == .inferNames)

        world.app.settings.settings.summaryService = .gemini
        await world.queue.run(.regenerate, on: meeting.id)

        let regenerated = try await world.library.meeting(meeting.id)
        #expect(regenerated.status == .completed)
        #expect(regenerated.outputs.summary != nil)
        #expect(regenerated.deferredAIStep == nil)
        #expect(world.catalog.llm.calls.get.contains("summarize"))

        world.catalog.llm.calls.set([])
        await world.queue.resumeDeferredAI()
        #expect(world.catalog.llm.calls.get.isEmpty)
        #expect(try await world.library.meeting(meeting.id) == regenerated)
    }

    @Test func deferredAIFailureKeepsItsMarkerAndRecordsTheFailedStep() async throws {
        let api = URL(string: "https://deferred.example.test")!
        let world = try World(keys: false, collabConfiguration: .init(apiURL: api, webURL: api))
        world.app.settings.settings = AppSettings()
        world.app.settings.settings.localSpeechModel = .breezeCoreML
        world.catalog.offlineDownloaded[.breezeCoreML]?.set(true)
        let meeting = try await world.recordedMeeting()
        try world.credentials.save(Secret(#"{"apiURL":"https://deferred.example.test","tokens":{"accessToken":"new-token","refreshToken":"new-refresh"}}"#), for: .collabAccount)
        world.catalog.llm.failNext.set(["summarize"])

        await world.queue.resumeDeferredAI()

        let failed = try await world.library.meeting(meeting.id)
        #expect(failed.deferredAIStep == .inferNames)
        let reason = FakeLLMError().description
        #expect(failed.status == .failed(step: .summarize, reason: reason))
        #expect(world.queue.jobs[meeting.id] == .failed(step: .summarize, reason: reason))

        await world.queue.resumeDeferredAI()
        #expect(try await world.library.meeting(meeting.id).deferredAIStep == nil)
    }

    @Test func legacyMeetingJSONDecodesWithoutDeferredAI() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        let data = try JSONEncoder().encode(meeting)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["deferredAIStep"] == nil)
        #expect(try JSONDecoder().decode(Meeting.self, from: data) == meeting)
    }

    @Test func signedOutMM2TWithoutTheDownloadedModelReportsOnlyTheTranscriptionIssue() async throws {
        let world = try World(keys: false)
        world.app.settings.settings = AppSettings()
        world.app.settings.settings.localSpeechModel = .breezeCoreML
        let meeting = try await world.recordedMeeting()
        #expect(world.queue.jobs[meeting.id] == .needsSetup([.transcriptionServiceNotConfigured(.mm2t)]))
        #expect(meeting.status == .pending(next: .transcribe))
        #expect(world.catalog.providerCalls == 0)
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
        #expect(issues == [.transcriptionServiceNotConfigured(.mm2t)])
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

    @Test(.serialized, arguments: [false, true])
    func hostedAccountChangesDoNotInterruptOwnLiveTranscription(signOut: Bool) async throws {
        let api = URL(string: "https://rotation.example")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingTokenProbe.self]
        let session = URLSession(configuration: configuration)
        RecordingTokenProbe.summaryRequests.set([])
        let world = try World(collabConfiguration: .init(apiURL: api, webURL: api), collabSession: session)
        let old = Secret(#"{"apiURL":"https://rotation.example","tokens":{"accessToken":"old-token","refreshToken":"old-refresh"}}"#)
        try world.credentials.save(old, for: .collabAccount)
        world.catalog.hostedLLMSession.set(session)
        world.catalog.selfHosted.behavior.set(.words)
        world.catalog.recordingDiarizer.set(RecordingTestDiarizer())
        world.app.settings.settings.transcriptionService = .server
        world.app.settings.settings.selfHostedURL = URL(string: "https://speech.example")
        world.app.settings.settings.summaryService = .mm2t
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "Token rotation", platform: .zoom))
        let recording = try #require(world.recorder.last)
        let directory = recording.configuration.directory

        func writeTracks(seconds: Int) throws {
            let samples = (0..<(16_000 * seconds)).map { Int16($0 % 32 < 16 ? 2200 : -2200) }
            try WAVFormat.write(WAVAudio(sampleRate: 16_000, samples: samples), to: directory.appending(path: RecordingManifest.micFile))
            try WAVFormat.write(WAVAudio(sampleRate: 16_000, samples: Array(repeating: 0, count: samples.count)),
                                to: directory.appending(path: RecordingManifest.remoteFile))
        }
        func waitForTranscription(seconds: TimeInterval) async throws -> Bool {
            let deadline = ContinuousClock.now + .seconds(8)
            repeat {
                if let progress = await world.capture.liveProgress(), progress.transcribedSeconds >= seconds { return true }
                try await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < deadline
            return false
        }

        try writeTracks(seconds: 35)
        #expect(try await waitForTranscription(seconds: 15))
        let account = try #require(world.app.collabAccount)
        if signOut {
            try await account.service.logout()
            #expect(try world.credentials.read(.collabAccount) == nil)
        } else {
            try await account.service.refresh()
            let newCredential = try #require(try world.credentials.read(.collabAccount))
            #expect(CollabService.storedAccessToken(newCredential, for: api) == "new-token")
        }

        try writeTracks(seconds: 65)
        await recording.useSuppliedTracks(duration: 65)
        #expect(try await waitForTranscription(seconds: 40), "live transcription reaches audio added after the account change")
        await world.capture.stop()

        let meetings = try await world.library.list()
        let meeting = try #require(meetings.first)
        #expect(meeting.transcription?.me.source == .selfHosted)
        let requests = RecordingTokenProbe.summaryRequests.get
        if signOut {
            #expect(meeting.status == .completed)
            #expect(meeting.outputs.summary == nil)
            #expect(meeting.deferredAIStep == .inferNames)
            #expect(requests.isEmpty, "no hosted request should use the signed-out token")

            let account = try #require(world.app.collabAccount)
            try await account.completeSignIn(code: "fixture", verifier: "fixture")
            try #require(await eventually {
                !RecordingTokenProbe.summaryRequests.get.isEmpty && !world.queue.isBusy(meeting.id)
            })
            let resumed = try await world.library.meeting(meeting.id)
            #expect(resumed.outputs.summary?.headline == "Summary with the rotated token")
            #expect(resumed.deferredAIStep == nil)
            #expect(RecordingTokenProbe.summaryRequests.get.allSatisfy {
                $0.value(forHTTPHeaderField: "X-MM2T-Purpose") == "auto"
            })
        } else {
            #expect(meeting.status == .completed)
            #expect(meeting.outputs.summary?.headline == "Summary with the rotated token")
            #expect(requests.count >= 3)
            let group = try #require(requests.first?.value(forHTTPHeaderField: "X-MM2T-Request"))
            #expect(UUID(uuidString: group) != nil)
            #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-MM2T-Request") == group })
            #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer new-token" })
            #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-MM2T-Purpose") == "auto" })
        }
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
        let queue = ProcessingQueue(makePipeline: { try setup.build(world.app.settings.settings) },
                                    makeLLM: { try setup.buildLLM(world.app.settings.settings) })
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

private final class RecordingTokenProbe: URLProtocol, @unchecked Sendable {
    static let summaryRequests = Box<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let status: Int
        let body: String
        switch (request.httpMethod, url.path) {
        case ("POST", "/v1/auth/exchange"), ("POST", "/v1/auth/refresh"):
            status = 200
            body = #"{"accessToken":"new-token","refreshToken":"new-refresh","user":{"id":"1","name":"Test","email":"test@example.test"}}"#
        case ("GET", "/v1/me"):
            status = 200
            body = #"{"user":{"id":"1","name":"Test","email":"test@example.test"},"quota":{"used":0,"limit":10,"period":"month"}}"#
        case ("POST", "/v1/auth/logout"):
            status = 200
            body = #"{"ok":true}"#
        case ("POST", "/v1/hosted/llm/chat/completions"):
            Self.summaryRequests.update { $0.append(request) }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer new-token" {
                status = 200
                body = #"{"choices":[{"message":{"content":"{\"guesses\":[],\"paragraphs\":[],\"digests\":[],\"headline\":\"Summary with the rotated token\",\"decisions\":[],\"discussionPoints\":[],\"actionItems\":[]}"},"finish_reason":"stop"}]}"#
            } else {
                status = 401
                body = "{}"
            }
        default:
            status = 404
            body = "{}"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
