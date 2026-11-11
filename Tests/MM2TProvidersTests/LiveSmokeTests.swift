import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TProviders

/// Calls the real services. Each test runs only when its key or URL is in the environment, e.g.
/// `MM2T_ELEVENLABS_API_KEY=... MM2T_LIVE_AUDIO=~/meeting.m4a swift test --filter LiveSmokeTests`.
/// `MM2T_LIVE_AUDIO` should be a short clip of Mandarin mixed with English.
@Suite struct LiveSmokeTests {
    static let env = ProcessInfo.processInfo.environment
    static var audio: URL? { env["MM2T_LIVE_AUDIO"].map { URL(filePath: ($0 as NSString).expandingTildeInPath) } }

    @Test(.enabled(if: env["MM2T_ELEVENLABS_API_KEY"] != nil))
    func elevenLabs() async throws {
        let scribe = ElevenLabsScribe(apiKey: Secret(Self.env["MM2T_ELEVENLABS_API_KEY"]!))
        #expect(await scribe.validateKey() == .valid)
        guard let audio = Self.audio else { return }
        let result = try await scribe.transcribe(audio: audio, hints: ["Kubernetes"], labelSpeakers: true)
        print("ElevenLabs words:", result.words.prefix(40).map { "\($0.text)@\($0.range.start)" })
        print("ElevenLabs labeled:", result.labeledWords != nil)
        #expect(!result.words.isEmpty)
    }

    @Test(.enabled(if: env["MM2T_SELF_HOSTED_URL"] != nil))
    func selfHosted() async throws {
        let server = SelfHostedTranscription(
            baseURL: URL(string: Self.env["MM2T_SELF_HOSTED_URL"]!)!,
            token: Self.env["MM2T_SELF_HOSTED_TOKEN"].map { Secret($0) })
        #expect(await server.validateKey() == .valid)
        guard let audio = Self.audio else { return }
        let result = try await server.transcribe(audio: audio, hints: ["Kubernetes"], labelSpeakers: true)
        print("Self-hosted words:", result.words.prefix(40).map { "\($0.text)@\($0.range.start)" })
        #expect(!result.words.isEmpty)
    }

    @Test(.enabled(if: env["MM2T_GEMINI_API_KEY"] != nil))
    func gemini() async throws {
        let llm = GeminiLLM(apiKey: Secret(Self.env["MM2T_GEMINI_API_KEY"]!), model: Self.env["MM2T_GEMINI_MODEL"] ?? GeminiLLM.defaultModel)
        #expect(await llm.validateKey() == .valid)
        let transcript = LLMTranscript(utterances: [
            utterance("u1", "r1", 0, "嗯那個小華你那邊 Kubernetes 的 migration 進度怎麼樣"),
            utterance("u2", "r2", 4, "呃就是我們禮拜三，不對，禮拜四之前會把 cluster 升級完", highlighted: true),
            utterance("u3", "me", 9, "OK 那我們就決定禮拜四上線，小華你負責寫 rollback plan"),
        ])
        let cleaned = try await llm.cleanTranscript(transcript)
        let summary = try await llm.summarize(SummaryRequest(transcript: transcript, prioritized: [transcript.utterances[1]]))
        let names = try await llm.inferNames(NameInferenceRequest(transcript: transcript, unnamedSpeakers: [SpeakerID("r2")], knownNames: [:]))
        print("Cleaned:", cleaned.paragraphs.map(\.text))
        print("Summary:", summary)
        print("Names:", names)
        #expect(!cleaned.paragraphs.isEmpty)
        #expect(names.first?.speaker == SpeakerID("r2"))
    }
}
