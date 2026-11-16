import Foundation
import MM2TApp
import MM2TCore
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
        #expect(flow.otherIssues.isEmpty, "every issue has its own field on the last step")

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
        #expect(flow.services.isEmpty)
        #expect(flow.otherIssues == [.offlineModelMissing(.transcription), .offlineModelMissing(.llm)],
                "issues without a field of their own are listed")
    }

    @Test func theLastStepWaitsForBothModelsAndSaysHowFarTheyAre() async throws {
        let world = try World()
        let flow = world.app.onboarding
        let setup = world.app.setup
        world.catalog.modelsDownloaded.set(false)
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
        let flow = world.app.onboarding
        #expect(world.app.setup.models == .downloaded)
        await flow.startDownloads()
        await flow.startDownloads()
        #expect(world.speakerInstaller.downloads.get == 0)
        #expect(world.translationInstaller.downloads.get == 1)
        #expect(flow.modelsReady && flow.modelProgress == 1)
    }
}
