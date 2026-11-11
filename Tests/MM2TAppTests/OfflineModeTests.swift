import Foundation
import MM2TCore
import MM2TLocal
import MM2TProviders
import Testing
@testable import MM2TApp

@MainActor @Suite struct OfflineModeTests {
    @Test func bothSwitchesOnProcessAMeetingWithoutAnyKeyOrNetworkProvider() async throws {
        let world = try World(keys: false)
        world.catalog.offlineDownloaded[.transcription]!.set(true)
        world.catalog.offlineDownloaded[.llm]!.set(true)
        world.app.settings.settings.transcriptionOrder = [.local]
        world.app.settings.settings.llmLocation = .local
        world.app.settings.settings.addVocabulary("mm2t", source: .manual)

        let meeting = try await world.recordedMeeting()
        let processed = try await world.library.meeting(meeting.id)

        #expect(world.queue.jobs[meeting.id] == .completed)
        #expect(processed.transcription?.remote.source == .local)
        #expect(processed.transcription?.me.source == .local)
        #expect(world.catalog.onDeviceSTT.calls.get.first?.hints == ["mm2t"])
        #expect(world.catalog.onDeviceLLM.calls.get == ["inferNames", "cleanTranscript", "digestPerPerson", "summarize"])
        #expect(processed.outputs.summary != nil)
        #expect(world.catalog.keysUsed.get.isEmpty, "story 61: fully offline needs no key")
        #expect(world.catalog.cloud.calls.get.isEmpty && world.catalog.llm.calls.get.isEmpty)
    }

    @Test func theChainFallsThroughToTheMacWhenSelfHostedAndCloudAreUnreachable() async throws {
        let world = try World()
        world.catalog.offlineDownloaded[.transcription]!.set(true)
        world.catalog.cloud.behavior.set(.unreachable)
        world.app.settings.settings.selfHostedURL = URL(string: "http://gpu.tailnet:8000")
        world.app.settings.settings.transcriptionOrder = [.selfHosted, .cloud, .local]

        let meeting = try await world.recordedMeeting()
        let processed = try await world.library.meeting(meeting.id)

        #expect(world.catalog.selfHosted.calls.get.count == 2)
        #expect(world.catalog.cloud.calls.get.count == 2)
        #expect(processed.transcription?.remote.source == .local, "story 64: the Mac is the last resort and is recorded")
        #expect(world.catalog.llm.calls.get.count == 4, "the LLM switch is independent and stays on Gemini")
    }

    @Test func turningOnAnOfflineSwitchAsksForItsDownloadAndTheDownloadClearsIt() async throws {
        let world = try World()
        let setup = world.app.setup
        world.app.settings.settings.llmLocation = .local
        setup.refresh()
        #expect(setup.offlineModels == [.transcription: .notDownloaded, .llm: .notDownloaded])
        #expect(setup.issues == [.offlineModelMissing(.llm)])

        await setup.downloadOfflineModel(.llm)
        #expect(setup.offlineModels[.llm] == .downloaded)
        #expect(setup.offlineModels[.transcription] == .notDownloaded, "each model downloads on its own")
        #expect(setup.issues.isEmpty)
    }

    @Test func aMeetingWaitingForTheModelRunsOnceItIsDownloaded() async throws {
        let world = try World(keys: false)
        world.app.settings.settings.transcriptionOrder = [.local]
        world.app.settings.settings.llmLocation = .local
        let meeting = try await world.recordedMeeting()
        #expect(world.queue.jobs[meeting.id] == .needsSetup([.offlineModelMissing(.transcription), .offlineModelMissing(.llm)]))

        await world.app.setup.downloadOfflineModel(.transcription)
        await world.app.setup.downloadOfflineModel(.llm)
        await world.queue.retryAfterSetup()
        #expect(world.queue.jobs[meeting.id] == .completed)
    }

    @Test func theSuggestionFollowsThisMacsChipAndMemory() throws {
        let roomy = try World(machine: MachineProfile(isAppleSilicon: true, memoryBytes: 32 << 30))
        #expect(roomy.app.setup.suitability == OfflineSuitability(MachineProfile(isAppleSilicon: true, memoryBytes: 32 << 30)))
        #expect(roomy.app.setup.suitability.llm == .suited)

        let small = try World(machine: MachineProfile(isAppleSilicon: true, memoryBytes: 8 << 30))
        #expect(small.app.setup.suitability.transcription == .suited)
        #expect(small.app.setup.suitability.llm == .unsuited(.memory(minimumGB: 16)))

        let intel = try World(machine: MachineProfile(isAppleSilicon: false, memoryBytes: 64 << 30))
        #expect(intel.app.setup.suitability.transcription == .unsuited(.intelProcessor))
        #expect(intel.app.setup.suitability.llm == .unsuited(.intelProcessor))
    }
}
