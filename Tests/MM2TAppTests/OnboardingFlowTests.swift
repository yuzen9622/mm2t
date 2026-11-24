import Foundation
@testable import MM2TApp
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

    @Test func servicesComeBeforePermissionsAndCaptionDownloadsAreNotRequired() async throws {
        let world = try firstRun()
        world.app.settings.settings.transcriptionService = .server
        world.app.settings.settings.summaryService = .openAICompatible
        let flow = world.app.onboarding
        #expect(flow.step == .usage && flow.choice == .ownKeys && flow.canContinue && !flow.canGoBack)
        #expect(flow.advance())
        #expect(flow.step == .services && !flow.canContinue)
        let elevenLabs = world.app.setup.field(.elevenLabsAPIKey)
        elevenLabs.text = "eleven"
        elevenLabs.save()
        #expect(!flow.canContinue)
        let gemini = world.app.setup.field(.geminiAPIKey)
        gemini.text = "gemini"
        gemini.save()
        #expect(world.app.settings.settings.transcriptionService == .server)
        #expect(world.app.settings.settings.summaryService == .openAICompatible)
        #expect(flow.advance())
        #expect(world.app.settings.settings.transcriptionService == .elevenLabs)
        #expect(world.app.settings.settings.summaryService == .gemini)
        #expect(flow.step == .permissions && flow.note == .needsMicrophone)
        world.permissions.mic.set(.granted)
        world.app.setup.refreshPermissions()
        #expect(flow.advance())
        #expect(flow.step == .models && flow.canContinue)
        #expect(flow.advance())
        #expect(flow.step == .voice && flow.primary == .start && !flow.canContinue)
        try await enrollVoice(world)
        await flow.startDownloads()
        #expect(flow.canContinue)
        #expect(world.offlineInstallers.values.allSatisfy { $0.downloads.get == 0 })
    }

    @Test func aRejectedKeyBlocksContinueEvenAfterRebuildingSetup() async throws {
        let world = try firstRun()
        let setup = world.app.setup
        let flow = world.app.onboarding
        #expect(flow.advance())
        let elevenLabs = setup.field(.elevenLabsAPIKey)
        elevenLabs.text = "eleven"
        elevenLabs.save()
        let gemini = setup.field(.geminiAPIKey)
        gemini.text = "bad"
        await gemini.validate()
        #expect(try world.credentials.read(.geminiAPIKey) == nil)
        #expect(!gemini.hasSavedValue)
        #expect(gemini.text == "bad")
        #expect(gemini.state == .checked(.rejected("Gemini API Key 無效")))
        #expect(!setup.isConfigured(.gemini, signedIn: false))
        #expect(!flow.canContinue && !flow.advance())

        let rebuiltSetup = SetupModel(permissions: world.permissions, installer: world.speakerInstaller,
            offlineInstallers: world.offlineInstallers, translationInstaller: { _, _ in world.translationInstaller },
            suitability: setup.suitability, credentials: world.credentials, validator: world.validator,
            settings: world.app.settings, runningBrowsers: { [] }, checkSetup: { [] })
        let rebuiltFlow = OnboardingFlow(setup: rebuiltSetup, settings: world.app.settings,
            enrollment: world.app.enrollment, account: nil)
        #expect(rebuiltFlow.advance())
        #expect(!rebuiltSetup.field(.geminiAPIKey).isConfigured)
        #expect(!rebuiltSetup.isConfigured(.gemini, signedIn: false))
        #expect(!rebuiltFlow.canContinue && !rebuiltFlow.advance())

        gemini.text = "timeout"
        await gemini.validate()
        #expect(gemini.state == .checked(.inconclusive("Could not reach Gemini")))
        #expect(try world.credentials.read(.geminiAPIKey) == Secret("timeout"))
        #expect(setup.isConfigured(.gemini, signedIn: false))
        #expect(flow.canContinue)
    }

    @Test func aRejectedReplacementKeepsThePreviouslySavedKey() async throws {
        let world = try World()
        let gemini = world.app.setup.field(.geminiAPIKey)
        gemini.text = "bad"
        await gemini.validate()
        #expect(try world.credentials.read(.geminiAPIKey) == Secret("gemini-key"))
        #expect(gemini.text == "bad")
        #expect(gemini.state == .checked(.rejected("Gemini API Key 無效")))
    }

    @Test func aValidKeyIsConfiguredAfterRebuildingTheField() async throws {
        let world = try firstRun()
        let gemini = world.app.setup.field(.geminiAPIKey)
        gemini.text = "valid-key"
        await gemini.validate()
        #expect(gemini.state == .checked(.valid))
        #expect(try world.credentials.read(.geminiAPIKey) == Secret("valid-key"))
        let rebuilt = CredentialField(credential: .geminiAPIKey, store: world.credentials,
            validator: world.validator, selfHostedURL: { nil })
        #expect(rebuilt.isConfigured)
    }

    @Test func independentSelectionsDownloadSharedWeightsOnlyOnce() async throws {
        let world = try firstRun()
        let setup = world.app.setup
        let installer = try #require(world.offlineInstallers[.parakeet])
        let gate = Gate<Bool>()
        installer.hold.set(gate)
        let first = setup.selectSpeechModel(.parakeet, for: \.localSpeechModel)
        #expect(world.app.settings.settings.effectiveCaptionModel == .parakeet)
        #expect(await eventually { setup.offlineModels[.parakeet] == .downloading(0.5) })
        await setup.selectSpeechModel(.parakeet, for: \.localCaptionModel).value
        await gate.open(true)
        await first.value
        await setup.selectSpeechModel(.parakeet, for: \.localSpeechModel).value
        #expect(installer.downloads.get == 1)
        await setup.selectSpeechModel(.nemotron, for: \.localCaptionModel).value
        let saved = SettingsStore(defaults: world.defaults).settings
        #expect(saved.localSpeechModel == .parakeet && saved.localCaptionModel == .nemotron)
        #expect(world.offlineInstallers[.nemotron]?.downloads.get == 1)
        await setup.selectSpeechModel(.parakeet, for: \.localCaptionModel).value
        await setup.selectSpeechModel(.nemotron, for: \.localSpeechModel).value
        let reopened = SettingsStore(defaults: world.defaults).settings
        #expect(reopened.localCaptionModel == nil && reopened.effectiveCaptionModel == .nemotron)
    }

    @Test func oldModelSettingsKeepTheirChoiceAndFreshSettingsStillNeedOneAfterReload() throws {
        let old = Data(#"{"localSpeechModel":"parakeet"}"#.utf8)
        let saved = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(saved.localSpeechModel == .parakeet && saved.effectiveCaptionModel == .parakeet)
        let fresh = try JSONEncoder().encode(AppSettings())
        #expect(try JSONDecoder().decode(AppSettings.self, from: fresh).effectiveCaptionModel == nil)
    }

    @Test func eachChoicePresentsOnlyItsEditorsAndDoesNotSaveBeforeContinue() throws {
        let world = try firstRun()
        let flow = world.app.onboarding
        let original = world.app.settings.settings
        let editors: [(OnboardingChoice, [ModelService])] = [
            (.plan, [.mm2t]), (.ownKeys, [.elevenLabs, .gemini]), (.ownServer, [.transcriptionServer, .openAICompatible]),
        ]
        for (choice, expected) in editors {
            flow.select(choice)
            #expect(flow.advance())
            #expect(flow.services == expected)
            #expect(!flow.canContinue)
            #expect(!flow.advance())
            #expect(world.app.settings.settings == original)
            flow.back()
            #expect(flow.step == .usage && !flow.forward)
        }
    }

    @Test func ownServersRequireBothURLsAndAModelWithoutKeys() throws {
        let world = try firstRun()
        let flow = world.app.onboarding
        flow.select(.ownServer)
        #expect(flow.advance())
        world.app.settings.settings.selfHostedURL = URL(string: "http://speech.example")
        #expect(!flow.canContinue)
        world.app.settings.settings.openAIBaseURL = URL(string: "http://llm.example/v1")
        #expect(!flow.canContinue)
        world.app.settings.settings.openAIModel = "qwen"
        #expect(flow.advance())
        #expect(world.app.settings.settings.transcriptionService == .server)
        #expect(world.app.settings.settings.summaryService == .openAICompatible)
        #expect(world.app.settings.settings.captionSources == [.local, .selfHosted])
    }

    @Test func planRequiresSignInAndConfiguresBothJobsTogether() async throws {
        let world = try firstRun()
        let api = URL(string: "https://onboarding.invalid")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OnboardingLogin.self]
        let account = CollabAccount(configuration: .init(apiURL: api, webURL: api), credentials: world.credentials,
                                    pendingEndsFile: world.root.appending(path: "pending.json"), session: URLSession(configuration: config))
        let flow = OnboardingFlow(setup: world.app.setup, settings: world.app.settings, enrollment: world.app.enrollment, account: account)
        flow.select(.plan)
        #expect(flow.advance() && !flow.canContinue)
        try await account.completeSignIn(code: "fixture", verifier: "fixture")
        #expect(flow.advance())
        #expect(world.app.settings.settings.transcriptionService == .mm2t)
        #expect(world.app.settings.settings.summaryService == .mm2t)
        #expect(world.app.settings.settings.captionSources == [.mm2t, .local])
    }

    @Test func reopeningRepairKeepsTheExistingPairOfServices() throws {
        let world = try World()
        let flow = world.app.onboarding
        world.app.settings.settings.hasCompletedOnboarding = true
        world.app.settings.settings.transcriptionService = .server
        flow.open()
        #expect(flow.step == .services && flow.services == [.transcriptionServer, .gemini])
        #expect(!flow.canContinue && !flow.canGoBack)
        world.app.settings.settings.selfHostedURL = URL(string: "https://speech.example")
        #expect(flow.advance())
        #expect(world.app.settings.settings.transcriptionService == .server)
        #expect(world.app.settings.settings.summaryService == .gemini)
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
        #expect(flow.step == .voice)
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

private final class OnboardingLogin: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "onboarding.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        let body = url.path.hasSuffix("/exchange")
            ? #"{"accessToken":"fixture-access","refreshToken":"fixture-refresh","user":{"id":"fixture","email":"user@example.invalid","name":"Fixture"}}"#
            : #"{"quota":{"used":0,"limit":10,"period":"month"},"user":{"id":"fixture","email":"user@example.invalid","name":"Fixture"}}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
