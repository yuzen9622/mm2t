import Foundation
import MM2TCore
import MM2TProviders
import Testing
@testable import MM2TApp

@MainActor @Suite struct LLMBackendTests {
    func build(_ world: World, _ change: (inout AppSettings) -> Void) throws -> PipelineBuild {
        let setup = PipelineSetup(library: world.library, voiceprints: world.app.voiceprints,
                                  credentials: world.credentials, catalog: world.catalog)
        var settings = AppSettings()
        change(&settings)
        return try setup.build(settings)
    }

    @Test func serverOriginsDefaultToV1WithoutChangingExplicitAPIRoots() {
        #expect(AppSettings.openAIBaseURL(from: "http://gpu:8000")?.path == "/v1")
        #expect(AppSettings.openAIBaseURL(from: "http://gpu:8000/v1")?.path == "/v1")
        #expect(AppSettings.openAIBaseURL(from: "http://gpu:8000/proxy/v1")?.path == "/proxy/v1")
        #expect(AppSettings.openAIBaseURL(from: "not a URL") == nil)
    }

    @Test func theOpenAICompatibleBackendNeedsAnEndpointButNoKey() throws {
        let world = try World(keys: false)
        world.credentials.values.update { $0[.elevenLabsAPIKey] = "eleven" }
        let url = try #require(AppSettings.openAIBaseURL(from: "http://gpu:8000/v1"))

        guard case .needsSetup(let issues) = try build(world, { $0.cloudLLM = .openAICompatible }) else {
            Issue.record("expected setup issues"); return
        }
        #expect(issues == [.missingLLMEndpoint])

        guard case .needsSetup(let noModel) = try build(world, { $0.cloudLLM = .openAICompatible; $0.openAIBaseURL = url }) else {
            Issue.record("expected setup issues"); return
        }
        #expect(noModel == [.missingLLMEndpoint])

        guard case .ready = try build(world, { $0.cloudLLM = .openAICompatible; $0.openAIBaseURL = url; $0.openAIModel = " qwen3 " }) else {
            Issue.record("expected a pipeline"); return
        }
        #expect(world.catalog.openAIEndpoints.get == ["http://gpu:8000/v1|-|qwen3"])

        world.credentials.values.update { $0[.openAICompatibleAPIKey] = "sk-local" }
        _ = try build(world, { $0.cloudLLM = .openAICompatible; $0.openAIBaseURL = url; $0.openAIModel = "qwen3" })
        #expect(world.catalog.openAIEndpoints.get.last == "http://gpu:8000/v1|sk-local|qwen3")
        #expect(!world.catalog.keysUsed.get.contains { $0.hasPrefix("llm:") }, "Gemini is not used")
    }

    @Test func verifyingTheKeyChecksTheConfiguredServer() async throws {
        let world = try World()
        let field = world.app.setup.field(.openAICompatibleAPIKey)
        field.text = "sk-local"
        await field.validate()
        #expect(field.state == .needsServerURL)

        let url = try #require(AppSettings.openAIBaseURL(from: "http://gpu:8000/v1"))
        world.app.settings.settings.openAIBaseURL = url
        world.app.settings.settings.openAIModel = "qwen3"
        await field.validate()
        #expect(field.state == .checked(.valid))
        #expect(world.validator.requests.get.last == .openAICompatible(baseURL: url, apiKey: "sk-local", model: "qwen3"))
    }

    @Test func theTranscriptionLanguageReachesEverySource() throws {
        let world = try World()
        world.catalog.offlineDownloaded[.transcription]!.set(true)
        world.catalog.languagesUsed.set([])
        _ = try build(world) { $0.transcriptionOrder = [.cloud, .local] }
        #expect(world.catalog.languagesUsed.get == [.auto, .auto])

        world.catalog.languagesUsed.set([])
        let url = try #require(AppSettings.selfHostedURL(from: "http://gpu:8080"))
        _ = try build(world) {
            $0.transcriptionOrder = [.selfHosted, .cloud, .local]
            $0.selfHostedURL = url
            $0.transcriptionLanguage = .english
        }
        #expect(world.catalog.languagesUsed.get == [.english, .english, .english])
    }

    @Test func settingsFromAnOlderBuildDefaultToAutoDetectAndGemini() throws {
        let old = #"{"transcriptionOrder":["cloud"],"llmLocation":"cloud"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        #expect(settings.transcriptionLanguage == .auto)
        #expect(settings.cloudLLM == .gemini)
        #expect(settings.openAIBaseURL == nil && settings.openAIModel.isEmpty)
        #expect(TranscriptionLanguage.auto.code == nil && TranscriptionLanguage.chinese.code == "zh" && TranscriptionLanguage.english.code == "en")
    }
}
