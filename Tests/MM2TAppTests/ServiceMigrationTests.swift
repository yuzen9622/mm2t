import Foundation
import Testing
@testable import MM2TApp

@Suite struct ServiceMigrationTests {
    @Test(arguments: [
        (#"{"transcriptionOrder":["cloud","selfHosted"]}"#, TranscriptionService.elevenLabs),
        (#"{"transcriptionOrder":["selfHosted","cloud"]}"#, .server),
        (#"{"transcriptionOrder":["local"],"selfHostedURL":"https://speech.example"}"#, .server),
        (#"{"transcriptionOrder":["local"]}"#, .elevenLabs),
        (#"{"transcriptionOrder":[]}"#, .elevenLabs),
        (#"{}"#, .elevenLabs),
    ])
    func migratesTranscription(json: String, expected: TranscriptionService) throws {
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)).transcriptionService == expected)
    }

    @Test(arguments: [
        (#"{"llmLocation":"local","cloudLLM":"gemini","openAIBaseURL":"https://llm.example/v1"}"#, SummaryService.openAICompatible),
        (#"{"llmLocation":"local","cloudLLM":"openAICompatible"}"#, .gemini),
        (#"{"llmLocation":"cloud","cloudLLM":"gemini"}"#, .gemini),
        (#"{"llmLocation":"cloud","cloudLLM":"openAICompatible"}"#, .openAICompatible),
        (#"{}"#, .gemini),
    ])
    func migratesSummary(json: String, expected: SummaryService) throws {
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)).summaryService == expected)
    }

    @Test func newKeysTakePrecedenceAndLegacyKeysAreNotEncoded() throws {
        let json = #"{"transcriptionService":"mm2t","summaryService":"mm2t","transcriptionOrder":["cloud"],"llmLocation":"cloud","cloudLLM":"gemini"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        #expect(encoded["transcriptionService"] as? String == "mm2t")
        #expect(encoded["summaryService"] as? String == "mm2t")
        for key in ["transcriptionOrder", "llmLocation", "cloudLLM"] { #expect(encoded[key] == nil) }
    }

    @Test func changingTheSpeechServiceDiscardsMigratedCaptionRoutes() throws {
        let legacy = Data(#"{"transcriptionOrder":["cloud","selfHosted","local"],"liveCaptions":true}"#.utf8)
        var settings = try JSONDecoder().decode(AppSettings.self, from: legacy)
        #expect(settings.captionSources == [.cloud, .selfHosted, .local])
        settings.transcriptionService = .server
        #expect(settings.captionSources == [.local, .selfHosted])
        let saved = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(saved.captionSources == [.local, .selfHosted])
        settings.transcriptionService = .mm2t
        #expect(settings.captionSources == [.local])
    }

    @MainActor @Test func decodingLegacyPreferencesDoesNotWriteOnLaunch() throws {
        let defaults = try #require(UserDefaults(suiteName: "mm2t-tests-\(UUID())"))
        let legacy = Data(#"{"transcriptionOrder":["local"],"llmLocation":"local"}"#.utf8)
        defaults.set(legacy, forKey: SettingsStore.key)
        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.transcriptionService == .elevenLabs)
        #expect(store.settings.summaryService == .gemini)
        #expect(defaults.data(forKey: SettingsStore.key) == legacy)
    }

}
