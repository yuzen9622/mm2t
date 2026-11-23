import Foundation
import MM2TCore
import MM2TLocal
import MM2TProviders
import Testing
@testable import MM2TApp

@MainActor @Suite struct OfflineModeTests {
    @Test func downloadsAndPersistsCaptionModelsWithoutBlockingProcessing() async throws {
        let world = try World()
        for choice in [LocalSpeechModel.nemotron, .parakeet, .breeze, .breezeCoreML] {
            await world.app.setup.selectSpeechModel(choice, for: \.localCaptionModel).value
            #expect(world.app.setup.offlineModels[OfflineModel(choice)] == .downloaded)
            #expect(world.app.setup.issues.isEmpty)
            let settings = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(world.app.settings.settings))
            #expect(settings.effectiveCaptionModel == choice)
        }
    }

    @Test func choosingCoreMLPreparesTheCompletedDownloadAndCanRetryWithoutDownloadingAgain() async throws {
        let world = try World()
        let installer = try #require(world.offlineInstallers[.breezeCoreML])
        var attempts = 0
        let setup = SetupModel(permissions: world.permissions, installer: world.speakerInstaller,
            offlineInstallers: world.offlineInstallers, translationInstaller: { _, _ in world.translationInstaller },
            suitability: world.app.setup.suitability, credentials: world.credentials, validator: world.validator,
            settings: world.app.settings, runningBrowsers: { [] }, prepareCoreML: {
                #expect(installer.isDownloaded)
                attempts += 1
                if attempts == 1 { throw FakeInstaller.Failed() }
            }, checkSetup: { [] })
        await setup.selectSpeechModel(.breezeCoreML, for: \.localSpeechModel).value
        #expect(setup.offlineModels[.breezeCoreML] == .downloaded)
        #expect(setup.coreMLPreparationError != nil)
        await setup.selectSpeechModel(.breezeCoreML, for: \.localSpeechModel).value
        #expect(attempts == 2 && installer.downloads.get == 1)
        #expect(!setup.preparingCoreML && setup.coreMLPreparationError == nil)
        #expect(world.app.settings.settings.localCaptionModel == nil)
        #expect(setup.speechModelChoices.contains(.breezeCoreML))
    }

    @Test func olderLocalConfigurationKeepsTheCoreMLCaptionModelOnRestart() throws {
        let before = Data(#"{"transcriptionOrder":["local"],"hasCompletedOnboarding":true}"#.utf8)
        let migrated = try JSONDecoder().decode(AppSettings.self, from: before)
        #expect(migrated.localSpeechModel == .breezeCoreML && migrated.effectiveCaptionModel == .breezeCoreML)
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(migrated)) == migrated)
        let fresh = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(fresh.effectiveCaptionModel == nil)
    }

    @Test func oldSharedFlagDoesNotSelectAnUninstalledMLXDefaultOnTheOtherPicker() throws {
        let defaults = UserDefaults(suiteName: "mm2t-tests-\(UUID())")!
        let data = Data(#"{"hasChosenSpeechModel":true,"localSpeechModel":"breezeCoreML","localCaptionModel":"breeze"}"#.utf8)
        defaults.set(data, forKey: SettingsStore.key)
        let machine = MachineProfile(isAppleSilicon: true, memoryBytes: 16 << 30)
        let migrated = SettingsStore(defaults: defaults, machine: machine, installedMLX: false)
        #expect(migrated.settings.localSpeechModel == .breezeCoreML && migrated.settings.localCaptionModel == nil)
        let reopened = SettingsStore(defaults: defaults, machine: machine, installedMLX: true)
        #expect(reopened.settings.localCaptionModel == .breeze)
        defaults.set(data, forKey: SettingsStore.key)
        #expect(SettingsStore(defaults: defaults, machine: machine, installedMLX: true).settings.localCaptionModel == .breeze)
    }

    @Test func intelUsesCompatibleModelsWithoutWritingAtLaunch() throws {
        let intel = MachineProfile(isAppleSilicon: false, memoryBytes: 16 << 30)
        let silicon = MachineProfile(isAppleSilicon: true, memoryBytes: 16 << 30)
        for caption in LocalSpeechModel.allCases {
            for transcript in LocalSpeechModel.allCases {
                let defaults = UserDefaults(suiteName: "mm2t-tests-\(UUID())")!
                var stored = AppSettings()
                stored.localCaptionModel = caption
                stored.localSpeechModel = transcript
                stored.hasCompletedOnboarding = true
                stored.transcriptionService = .server
                stored.addVocabulary("mm2t", source: .manual)
                defaults.set(try JSONEncoder().encode(stored), forKey: SettingsStore.key)
                #expect(SettingsStore(defaults: defaults, machine: silicon).settings == stored)
                let migrated = SettingsStore(defaults: defaults, machine: intel).settings
                if caption != .whisperCPU { stored.localCaptionModel = .whisperCPU }
                if transcript != .whisperCPU { stored.localSpeechModel = .whisperCPU }
                #expect(migrated == stored)
                #expect(SettingsStore(defaults: defaults, machine: silicon).settings.localCaptionModel == caption)
            }
        }
    }

    @Test func intelOffersCompatibleChoicesForBothUsesAndCannotDownloadMLX() async throws {
        let world = try World(machine: MachineProfile(isAppleSilicon: false, memoryBytes: 16 << 30))
        let setup = world.app.setup
        let store = world.app.settings
        #expect(store.settings.localSpeechModel == nil)
        #expect(world.app.onboarding.canLeave(.models))
        #expect(store.settings.localCaptionModel == nil && store.settings.localSpeechModel == nil)
        #expect(setup.speechModelChoices == [.whisperCPU])
        for field in [\AppSettings.localCaptionModel, \AppSettings.localSpeechModel] {
            await setup.selectSpeechModel(.breeze, for: field).value
        }
        #expect(store.settings.localSpeechModel == nil)
        await setup.downloadOfflineModel(.transcription)
        #expect(world.offlineInstallers[.transcription]?.downloads.get == 0)
        #expect(setup.offlineModels[.transcription] == nil)
        await setup.selectSpeechModel(.whisperCPU, for: \.localCaptionModel).value
        #expect(world.app.onboarding.canLeave(.models))
        #expect(store.settings.localSpeechModel == nil)
        await setup.selectSpeechModel(.whisperCPU, for: \.localSpeechModel).value
        #expect(world.app.onboarding.canLeave(.models))
        #expect(setup.speechModelChoices.contains(.whisperCPU))
        #expect(store.settings.localSpeechModel == .whisperCPU)
        #expect(!world.app.shouldPrepareBreeze)
        let rosetta = try World(machine: MachineProfile(isAppleSilicon: true, memoryBytes: 16 << 30, isTranslated: true))
        #expect(rosetta.app.setup.speechModelChoices == [.breeze, .whisperCPU])
        let silicon = try World()
        #expect(silicon.app.setup.speechModelChoices == LocalSpeechModel.allCases.filter { $0 != .whisperCPU })
        silicon.app.settings.settings.localCaptionModel = .whisperCPU
        #expect(silicon.app.setup.speechModelChoices == LocalSpeechModel.allCases)
    }

    @Test func rosettaFallbackPreservesNativeSelectionsUntilExplicitlyChanged() throws {
        let defaults = UserDefaults(suiteName: "mm2t-tests-\(UUID())")!
        let native = MachineProfile(isAppleSilicon: true, memoryBytes: 16 << 30)
        let translated = MachineProfile(isAppleSilicon: true, memoryBytes: 16 << 30, isTranslated: true)
        let original = SettingsStore(defaults: defaults, machine: native)
        original.settings.localCaptionModel = .parakeet
        original.settings.localSpeechModel = .nemotron
        let rosetta = SettingsStore(defaults: defaults, machine: translated)
        #expect(rosetta.settings.localCaptionModel == .whisperCPU)
        rosetta.settings.hasCompletedOnboarding = true
        #expect(SettingsStore(defaults: defaults, machine: native).settings.localCaptionModel == .parakeet)
        rosetta.chooseSpeechModel(.whisperCPU, for: \.localCaptionModel)
        let restarted = SettingsStore(defaults: defaults, machine: native).settings
        #expect(restarted.localCaptionModel == .whisperCPU && restarted.localSpeechModel == .nemotron)
    }

    @Test func independentCaptionSelectionMigratesAndSurvivesRestart() throws {
        let old = Data(#"{"localSpeechModel":"parakeet"}"#.utf8)
        var settings = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(settings.effectiveCaptionModel == .parakeet)
        settings.localSpeechModel = .breeze
        #expect(settings.effectiveCaptionModel == .breeze)
        let fingerprint = settings.forProcessing
        settings.localCaptionModel = .nemotron
        #expect(settings.forProcessing == fingerprint)
        let saved = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(saved.effectiveCaptionModel == .nemotron && saved.localSpeechModel == .breeze)
        settings = saved
        settings.localCaptionModel = nil
        let inherited = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(inherited.effectiveCaptionModel == .breeze && inherited.localCaptionModel == nil)
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
