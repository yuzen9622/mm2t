import Foundation
import Testing
@testable import MM2TApp
import MM2TCore

@MainActor @Suite struct CaptionEngineTests {
    @Test func legacySettingsKeepFirefoxAndEveryChoiceSurvivesRestart() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"captionTranslation":"japanese"}"#.utf8))
        #expect(legacy.captionEngine == .firefox)
        #expect(legacy.captionTranslation.target == .japanese)
        #expect(AppSettings().captionEngine == CaptionEngine.initial)
        let defaults = try #require(UserDefaults(suiteName: "mm2t-tests-\(UUID())"))
        let store = SettingsStore(defaults: defaults)
        for engine in CaptionEngine.allCases {
            store.settings.captionEngine = engine
            store.settings.captionTranslation = CaptionTranslation(engine == .firefox ? .japanese : CaptionTarget(languageCode: "vi"))
            let reloaded = SettingsStore(defaults: defaults).settings
            #expect(reloaded.captionEngine == engine)
            #expect(reloaded.captionTranslation == store.settings.captionTranslation)
            #expect(reloaded.forProcessing == legacy.forProcessing)
        }
    }

    @Test func engineSwitchDoesNotDownloadAndUnsupportedChoiceIsCleared() async throws {
        let world = try World()
        let app = world.app
        await app.setCaptionEngine(.hyMT2)
        await app.setCaptionTranslation(CaptionTranslation(try #require(CaptionTarget(languageCode: "vi"))))
        #expect(world.translationInstaller.downloads.get == 0)
        #expect(app.setup.translationModels == .notDownloaded)
        await app.onboarding.startDownloads()
        #expect(world.translationInstaller.downloads.get == 0, "Opening onboarding must not fetch the shared Hy-MT2 file")
        await app.setup.downloadTranslationModels()
        #expect(world.translationInstaller.downloads.get == 1)
        await app.setCaptionEngine(.firefox)
        #expect(app.settings.settings.captionTranslation == .off)
        #expect(world.translationInstaller.downloads.get == 1)
        if #available(macOS 26, *) {
            await app.setCaptionEngine(.apple)
            await app.setCaptionTranslation(CaptionTranslation(.english))
            await app.setup.downloadTranslationModels()
            #expect(app.setup.translationTarget == nil)
            #expect(world.translationInstaller.downloads.get == 1)
        }
    }

    @Test func languageListsAndRoutesFollowTheSelectedModel() throws {
        #expect(CaptionTarget.hyTargets.count == 38)
        #expect(CaptionTarget.hyTargets.allSatisfy { $0.flag.unicodeScalars.count == 2 })
        #expect(CaptionTarget(languageCode: "fr")?.flag == "🇫🇷")
        #expect(CaptionTarget(languageCode: "vi")?.flag == "🇻🇳")
        #expect(Set(CaptionTarget.hyTargets.map(\.id)).count == CaptionTarget.hyTargets.count)
        #expect(CaptionTarget(languageCode: "zh-Hant-TW") == .traditionalChinese)
        #expect(CaptionTarget(languageCode: "en-US") == .english)
        #expect(CaptionTarget.japanese.route(from: .traditionalChinese, engine: .firefox) == .models(["zh_hant", "en", "ja"]))
        for engine in [CaptionEngine.apple, .hyMT2] {
            #expect(CaptionTarget.japanese.route(from: .traditionalChinese, engine: engine) == .models(["zh_hant", "ja"]))
        }
    }
}
