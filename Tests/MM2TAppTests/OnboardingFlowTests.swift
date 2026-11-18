import Foundation
import MM2TApp
import MM2TCore
import MM2TProviders
import Testing

@MainActor
@Suite struct OnboardingFlowTests {
    /// A first run: nothing granted, no models, no voice, no keys.
    private func firstRun() throws -> World {
        let world = try World(keys: false)
        world.catalog.modelsDownloaded.set(false)
        world.permissions.mic.set(.notDetermined)
        world.app.setup.refresh()
        world.app.onboarding.reopen()
        return world
    }

    private func enrollVoice(_ world: World) async throws {
        try await world.app.voiceprints.enrollUser(name: "我", embeddings: [Embedding([0, 1, 0])])
        await world.app.enrollment.refresh()
    }

    @Test func eachStepContinuesOnlyOnceItsOwnRequirementIsMet() async throws {
        let world = try firstRun()
        let flow = world.app.onboarding
        #expect(flow.step == .usage)
        #expect(flow.choice == .ownKeys, "own keys is chosen by default")
        #expect(flow.canContinue && !flow.canGoBack)
        #expect(flow.advance())

        #expect(flow.step == .permissions)
        #expect(!flow.canContinue, "the microphone comes first")
        #expect(!flow.advance())
        #expect(flow.step == .permissions)
        world.permissions.mic.set(.granted)
        world.app.setup.refreshPermissions()
        #expect(flow.canContinue, "the other permissions may wait")
        flow.advance()

        #expect(flow.step == .models)
        #expect(flow.canContinue, "the downloads carry on in the background")
        flow.advance()

        #expect(flow.step == .voice)
        #expect(!flow.canContinue)
        try await enrollVoice(world)
        #expect(flow.canContinue)
        flow.advance()

        #expect(flow.step == .services)
        #expect(!flow.canContinue, "keys and models are still missing")
        #expect(!flow.advance(), "the last step finishes instead of moving on")
        try world.credentials.save("eleven-key", for: .elevenLabsAPIKey)
        try world.credentials.save("gemini-key", for: .geminiAPIKey)
        world.app.setup.recheck()
        #expect(!flow.canContinue, "both models have to be downloaded too")
        await flow.startDownloads()
        #expect(flow.canContinue)
        #expect(flow.step == .services)
    }

    @Test func backReversesTheTravelAndForwardRestoresIt() throws {
        let world = try World()
        let flow = world.app.onboarding
        flow.reopen()
        #expect(flow.step == .usage && flow.forward)
        flow.advance()
        flow.advance()
        #expect(flow.step == .models && flow.forward)
        flow.back()
        #expect(flow.step == .permissions && !flow.forward)
        flow.advance()
        #expect(flow.step == .models && flow.forward)
        flow.back()
        flow.back()
        #expect(flow.step == .usage && !flow.canGoBack)
        flow.back()
        #expect(flow.step == .usage, "nothing before the first step")
    }

    @Test func reopeningStartsAtTheFirstIncompleteStep() async throws {
        let world = try firstRun()
        let flow = world.app.onboarding
        world.app.settings.settings.hasCompletedOnboarding = true
        flow.reopen()
        #expect(flow.step == .permissions, "microphone not granted yet")

        world.permissions.mic.set(.granted)
        world.app.setup.refresh()
        flow.reopen()
        #expect(flow.step == .models, "models count as done only once downloaded")

        await flow.startDownloads()
        flow.reopen()
        #expect(flow.step == .voice)

        try await enrollVoice(world)
        flow.reopen()
        #expect(flow.step == .services, "the keys are still missing")
        flow.back()
        #expect(flow.step == .voice, "completed steps stay reachable")

        try world.credentials.save("eleven-key", for: .elevenLabsAPIKey)
        try world.credentials.save("gemini-key", for: .geminiAPIKey)
        world.app.setup.recheck()
        flow.reopen()
        #expect(flow.step == .services, "everything is met: the last step")
        #expect(flow.forward)
    }

    @Test func beforeSetupWasEverFinishedItReopensAtTheChoice() async throws {
        let world = try World()
        try await enrollVoice(world)
        world.app.onboarding.reopen()
        #expect(world.app.onboarding.step == .usage)
    }

    @Test func theChoiceIsWrittenIntoTheExistingSettings() throws {
        let world = try World()
        let flow = world.app.onboarding
        let store = world.app.settings

        flow.select(.signIn)
        #expect(flow.choice == .ownKeys, "signing in is not offered yet")

        flow.select(.ownServer)
        #expect(flow.choice == .ownServer)
        #expect(store.settings.transcriptionOrder == [.selfHosted])
        #expect(store.settings.llmLocation == .cloud && store.settings.cloudLLM == .openAICompatible)
        #expect(flow.services == [.transcriptionServer, .llmServer])
        #expect(world.app.setup.issues.contains(.missingSelfHostedURL), "the issues follow the new settings")
        #expect(world.app.setup.issues.allSatisfy { OnboardingFlow.entry(for: $0).map(flow.services.contains) ?? true },
                "every issue has its own row on the last step")

        flow.select(.ownKeys)
        #expect(store.settings.transcriptionOrder == [.cloud])
        #expect(store.settings.llmLocation == .cloud && store.settings.cloudLLM == .gemini)
        #expect(flow.services == [.elevenLabs, .gemini])
        #expect(world.app.setup.issues.isEmpty)
    }

    @Test func reopeningKeepsTheUsersOwnMixOfSettings() throws {
        let world = try World()
        let store = world.app.settings
        store.settings.transcriptionOrder = [.selfHosted, .cloud]
        store.settings.cloudLLM = .gemini
        let flow = world.app.onboarding
        flow.reopen()
        #expect(flow.choice == .ownServer)
        flow.select(.ownServer)
        #expect(store.settings.transcriptionOrder == [.selfHosted, .cloud], "choosing what is set changes nothing")
        #expect(flow.services == [.transcriptionServer, .elevenLabs, .gemini])

        store.settings.transcriptionOrder = [.local]
        store.settings.llmLocation = .local
        world.app.setup.recheck()
        flow.reopen()
        #expect(flow.choice == .ownKeys)
        #expect(flow.services == [.offlineModel(.transcription), .offlineModel(.llm)])
        #expect(flow.note == nil, "not on the last step")
    }

    /// Every issue there is, so that a new one cannot be left without a row.
    private static var everyIssue: [SetupIssue] {
        let issues: [SetupIssue] = Credential.allCases.map { .missingCredential($0) }
            + [.missingSelfHostedURL, .missingLLMEndpoint, .noTranscriptionSource, .diarizationModelsMissing]
            + OfflineModel.allCases.map { .offlineModelMissing($0) }
        // Fails to compile when SetupIssue gains a case, until it is added above.
        for issue in issues {
            switch issue {
            case .missingCredential, .missingSelfHostedURL, .missingLLMEndpoint, .noTranscriptionSource,
                 .diarizationModelsMissing, .offlineModelMissing: break
            }
        }
        return issues
    }

    @Test func everyIssueIsResolvedOnTheLastStepOrByAnEarlierOne() {
        var keys = AppSettings()
        keys.transcriptionOrder = [.cloud]
        var server = AppSettings()
        server.transcriptionOrder = [.selfHosted]
        server.cloudLLM = .openAICompatible
        var none = AppSettings()
        none.transcriptionOrder = []
        none.llmLocation = .local
        for settings in [keys, server, none] {
            for issue in Self.everyIssue {
                let services = OnboardingFlow.services(settings: settings, issues: [issue])
                if let entry = OnboardingFlow.entry(for: issue) {
                    #expect(services.contains(entry), "\(issue) has a row")
                } else {
                    #expect(issue == .diarizationModelsMissing, "only the speaker model is left to the models step")
                }
            }
            let all = OnboardingFlow.services(settings: settings, issues: Self.everyIssue)
            #expect(Set(all).count == all.count, "no row twice")
        }
        #expect(OnboardingFlow.entry(for: .offlineModelMissing(.transcription)) == .offlineModel(.transcription))
        #expect(OnboardingFlow.entry(for: .noTranscriptionSource) == .transcriptionSource)
        #expect(OnboardingFlow.entry(for: .missingSelfHostedURL) == .transcriptionServer)
        #expect(OnboardingFlow.entry(for: .missingCredential(.googleCalendarRefreshToken)) == .settings(.missingCredential(.googleCalendarRefreshToken)))
    }

    /// The last step with keys stored, both models in and the voice enrolled.
    private func atTheLastStep(_ change: (inout AppSettings) -> Void) async throws -> World {
        let world = try World()
        world.catalog.translationDownloaded.set(true)
        try await enrollVoice(world)
        world.app.settings.settings.hasCompletedOnboarding = true
        change(&world.app.settings.settings)
        world.app.setup.refresh()
        world.app.onboarding.reopen()
        #expect(world.app.onboarding.step == .services)
        return world
    }

    @Test func aMissingOnDeviceModelIsDownloadedOnTheLastStep() async throws {
        let world = try await atTheLastStep {
            $0.transcriptionOrder = [.cloud, .local]
            $0.captionTranslation = CaptionTranslation(.traditionalChinese)
        }
        let flow = world.app.onboarding
        let setup = world.app.setup
        #expect(flow.services == [.elevenLabs, .offlineModel(.transcription), .gemini])
        #expect(!flow.canContinue)
        #expect(flow.note == .issue(.offlineModelMissing(.transcription)))

        let gate = Gate<Bool>()
        world.offlineInstallers[.transcription]!.hold.set(gate)
        let download = Task { await setup.downloadOfflineModel(.transcription) }
        #expect(await eventually { setup.offlineModels[.transcription] == .downloading(0.5) })
        // 220 MB + 75 MB done, 1 GB half way.
        #expect(flow.note == .finishingDownloads((295 + 500) / 1295.0))

        await gate.open(false)
        await download.value
        #expect(flow.note == .issue(.offlineModelMissing(.transcription)), "Retry is in the row")

        world.offlineInstallers[.transcription]!.hold.set(nil)
        await setup.downloadOfflineModel(.transcription)
        #expect(setup.issues.isEmpty)
        #expect(flow.canContinue && flow.note == nil)
        #expect(flow.services.contains(.offlineModel(.transcription)), "the row stays, now with its check")
    }

    @Test func turningAnOnDeviceSourceOffClearsItsIssue() async throws {
        let world = try await atTheLastStep { $0.transcriptionOrder = [.selfHosted, .local]; $0.llmLocation = .local }
        let flow = world.app.onboarding
        let store = world.app.settings
        store.settings.selfHostedURL = URL(string: "http://gpu.tailnet:8000")
        world.app.setup.recheck()
        #expect(world.app.setup.issues == [.offlineModelMissing(.transcription), .offlineModelMissing(.llm)])

        flow.turnOff(.transcription)
        #expect(store.settings.transcriptionOrder == [.selfHosted], "the same as the Settings switch")
        flow.turnOff(.llm)
        #expect(store.settings.llmLocation == .cloud)
        #expect(world.app.setup.issues.isEmpty)
        #expect(flow.services == [.transcriptionServer, .gemini])
        #expect(flow.canContinue)
    }

    @Test func turningTheOnlySourceOffOffersTheChosenOneBack() async throws {
        let world = try await atTheLastStep { $0.transcriptionOrder = [.local] }
        let flow = world.app.onboarding
        flow.turnOff(.transcription)
        #expect(world.app.setup.issues == [.noTranscriptionSource])
        #expect(flow.services == [.gemini, .transcriptionSource])
        #expect(flow.note == .issue(.noTranscriptionSource))
        flow.turnOnTranscriptionSource()
        #expect(world.app.settings.settings.transcriptionOrder == [.cloud])
        #expect(flow.services == [.elevenLabs, .gemini])
        #expect(flow.canContinue)
    }

    @Test func aDisabledPrimaryAlwaysSaysWhy() async throws {
        let world = try firstRun()
        let flow = world.app.onboarding
        func check() { #expect(flow.canContinue == (flow.note == nil), "step \(flow.step)") }
        check()
        flow.advance()
        check()
        #expect(flow.note == .needsMicrophone)
        world.permissions.mic.set(.granted)
        world.app.setup.refreshPermissions()
        check()
        flow.advance()
        check()
        flow.advance()
        check()
        #expect(flow.note == .needsVoice)
        try await enrollVoice(world)
        check()
        flow.advance()
        check()
        #expect(flow.note == .issue(.missingCredential(.elevenLabsAPIKey)))
        try world.credentials.save("eleven-key", for: .elevenLabsAPIKey)
        world.app.setup.recheck()
        #expect(flow.note == .issue(.missingCredential(.geminiAPIKey)))
        try world.credentials.save("gemini-key", for: .geminiAPIKey)
        world.app.setup.recheck()
        check()
        #expect(flow.note == .modelsNotDownloaded, "keys are in; the models never started")
        await flow.startDownloads()
        check()
        #expect(flow.note == nil)
    }

    @Test func theLastStepWaitsForBothModelsAndSaysHowFarTheyAre() async throws {
        let world = try World()
        let flow = world.app.onboarding
        let setup = world.app.setup
        world.catalog.modelsDownloaded.set(false)
        world.app.settings.settings.captionTranslation = CaptionTranslation(.traditionalChinese)
        setup.refresh()
        try await enrollVoice(world)
        world.app.settings.settings.hasCompletedOnboarding = true
        flow.reopen()
        #expect(flow.step == .models)
        #expect(flow.primary == .continue)
        #expect(flow.note == nil, "only the last step has a note")
        #expect(flow.modelBytes == 295_000_000)

        let speakers = Gate<Bool>()
        let translation = Gate<Bool>()
        world.speakerInstaller.hold.set(speakers)
        world.translationInstaller.hold.set(translation)
        let downloads = Task { await flow.startDownloads() }
        #expect(await eventually { setup.models == .downloading(0.5) && setup.translationModels == .downloading(0.5) })
        flow.advance()
        flow.advance()
        #expect(flow.step == .services)
        #expect(flow.primary == .start)
        #expect(!flow.canContinue)
        #expect(flow.note == .finishingDownloads(0.5))

        await speakers.open(true)
        #expect(await eventually { setup.models == .downloaded })
        let expected = (220.0 + 0.5 * 75) / 295
        #expect(abs(flow.modelProgress - expected) < 0.0001, "weighted by size")
        #expect(flow.note == .finishingDownloads(flow.modelProgress))

        await translation.open(false)
        await downloads.value
        #expect(flow.note == .downloadFailed)
        #expect(!flow.canContinue)

        await flow.startDownloads()
        #expect(world.translationInstaller.downloads.get == 1, "a failed download waits for its Retry")
        world.translationInstaller.hold.set(nil)
        await setup.downloadTranslationModels()
        #expect(flow.note == nil)
        #expect(flow.canContinue)
    }

    @Test func downloadsStartOnceAndSkipWhatIsInstalled() async throws {
        let world = try World()
        world.app.settings.settings.captionTranslation = CaptionTranslation(.traditionalChinese)
        world.app.setup.refresh()
        let flow = world.app.onboarding
        #expect(world.app.setup.models == .downloaded)
        await flow.startDownloads()
        await flow.startDownloads()
        #expect(world.speakerInstaller.downloads.get == 0)
        #expect(world.translationInstaller.downloads.get == 1)
        #expect(flow.modelsReady && flow.modelProgress == 1)
    }
}

@MainActor
@Suite struct SetupInTheMainWindowTests {
    @Test func aFirstRunShowsSetupFromTheStart() throws {
        let world = try World()
        #expect(world.app.showsSetup, "known before the voiceprints are read")
    }

    @Test func aFinishedSetupShowsTheAppBeforeAndAfterTheVoiceprintsAreRead() async throws {
        let world = try World()
        world.app.settings.settings.hasCompletedOnboarding = true
        #expect(!world.app.showsSetup, "no flash of setup while the voiceprints load")
        try await world.app.voiceprints.enrollUser(name: "我", embeddings: [Embedding([0, 1, 0])])
        await world.app.enrollment.refresh()
        #expect(!world.app.showsSetup)
    }

    @Test func aMissingVoiceBringsSetupBackOnceKnown() async throws {
        let world = try World()
        world.app.settings.settings.hasCompletedOnboarding = true
        world.catalog.translationDownloaded.set(true)
        world.app.setup.refresh()
        await world.app.enrollment.refresh()
        #expect(world.app.showsSetup)
        #expect(world.app.onboarding.firstIncompleteStep == .voice)
    }

    @Test func finishingLeavesSetupForTheApp() async throws {
        let world = try World()
        try await world.app.voiceprints.enrollUser(name: "我", embeddings: [Embedding([0, 1, 0])])
        await world.app.enrollment.refresh()
        #expect(world.app.showsSetup)
        world.app.completeOnboarding()
        #expect(!world.app.showsSetup)
    }

    @Test func setupOpenedAgainShowsUntilFinishedOrClosed() async throws {
        let world = try World()
        world.app.settings.settings.hasCompletedOnboarding = true
        try await world.app.voiceprints.enrollUser(name: "我", embeddings: [Embedding([0, 1, 0])])
        await world.app.enrollment.refresh()
        world.catalog.modelsDownloaded.set(false)
        world.app.setup.refresh()

        world.app.openSetup()
        #expect(world.app.showsSetup)
        #expect(world.app.onboarding.step == .models, "at the first incomplete step")
        world.app.closeSetup()
        #expect(!world.app.showsSetup)

        world.app.openSetup()
        world.app.completeOnboarding()
        #expect(!world.app.showsSetup)
        #expect(!world.app.onboarding.isOpenedAgain)
    }

    @Test func closingCannotSkipUnfinishedSetup() throws {
        let world = try World()
        world.app.openSetup()
        world.app.closeSetup()
        #expect(world.app.showsSetup)
    }

    @Test func setupCanBeClosedOnlyWhenOpenedAgainFromAFinishedApp() async throws {
        let world = try World()
        world.app.openSetup()
        #expect(!world.app.canCloseSetup, "first run: never")

        world.app.settings.settings.hasCompletedOnboarding = true
        await world.app.enrollment.refresh()
        world.app.closeSetup()
        world.app.openSetup()
        #expect(!world.app.canCloseSetup, "no voiceprint: setup still blocks the app")

        try await world.app.voiceprints.enrollUser(name: "我", embeddings: [Embedding([0, 1, 0])])
        await world.app.enrollment.refresh()
        #expect(world.app.canCloseSetup)
        world.app.closeSetup()
        #expect(!world.app.showsSetup && !world.app.canCloseSetup)
    }

    @Test func withTranslationOffSetupNeitherWaitsForNorCountsTranslationModels() async throws {
        let world = try World()
        let flow = world.app.onboarding
        #expect(world.app.setup.translationTarget == nil)
        #expect(flow.modelBytes == 220_000_000, "the speaker model alone")
        await flow.startDownloads()
        #expect(world.translationInstaller.downloads.get == 0)
        #expect(flow.modelsReady)
        world.app.settings.settings.captionTranslation = CaptionTranslation(.japanese)
        world.app.setup.refresh()
        #expect(flow.modelBytes == 295_000_000, "follows the chosen language's models")
        #expect(!flow.modelsReady)
    }
}
