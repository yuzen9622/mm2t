import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TProviders

@Suite struct GenerationSnapshotTests {
    private let transcript = LLMTranscript(utterances: [utterance("u1", "r1", 0, "下次會議上午10.5")])
    private let clean = #"{"paragraphs":[{"speaker":"r1","text":"下次會議上午10:30","sources":["u1"]}]}"#
    private let summary = #"{"decisions":[],"discussionPoints":[],"actionItems":[]}"#
    private let summaryDelta = #"{"headline":null,"title":null,"decisions":{"remove":[],"replace":[],"append":[]},"discussionPoints":{"remove":[],"replace":[],"append":[]},"actionItems":{"remove":[],"replace":[],"append":[]}}"#

    @Test(arguments: [false, true])
    func heldCleanupCannotChangeOneGenerationsReferenceBetweenDigestAndSummary(_ hasPrevious: Bool) async throws {
        let store = CleanedCheckpointStore()
        if hasPrevious {
            let previous = CleanedTranscript(paragraphs: [.init(speaker: SpeakerID("r1"), text: "原先10:05", sources: [UtteranceID("u1")])])
            await store.accept(previous, for: transcript, revision: await store.begin())
        }
        let generator = HeldCleanup(clean: clean, summary: summary, summaryDelta: summaryDelta)
        let summaries = SummaryCheckpointStore(), digests = DigestCheckpointStore()
        func tasks(_ snapshot: CleanedCheckpointStore.Snapshot) -> LLMTasks {
            LLMTasks(generator, cleanChunkCharacters: 300, maxInputCharacters: 40_000, cleanConcurrency: 4,
                     responseCache: nil, summaryUpdates: summaries, digestUpdates: digests,
                     cleanedCheckpoints: store, normalizationSnapshot: snapshot)
        }
        let generation = tasks(await store.snapshot())
        let cleanup = Task { try await generation.cleanTranscript(transcript) }
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await generator.cleanupStarted), ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await generator.cleanupStarted)
        _ = try await generation.digestPerPerson(transcript)
        await generator.release()
        _ = try await cleanup.value
        _ = try await generation.summarize(SummaryRequest(transcript: transcript, prioritized: []))
        let firstDigest = try #require(await generator.digestInputs.first)
        let firstSummary = try #require(await generator.summaryInputs.first)
        #expect(firstDigest.contains("10:05") == hasPrevious)
        #expect(firstSummary.contains("10:05") == hasPrevious)
        #expect(!firstDigest.contains("10:30") && !firstSummary.contains("10:30"))

        let next = tasks(await store.snapshot())
        _ = try await next.digestPerPerson(transcript)
        _ = try await next.summarize(SummaryRequest(transcript: transcript, prioritized: []))
        #expect(await generator.digestInputs.count == 2)
        #expect(await generator.summaryInputs.count == 2)
        #expect(await generator.digestInputs.last?.contains("10:30") == true)
        #expect(await generator.summaryInputs.last?.contains("10:30") == true)
    }

    @Test(arguments: ["gemini", "openAICompatible"])
    func providerGenerationCopiesPinNilAndThenSeeCompletedReferencesOnTheNextCopy(_ provider: String) async throws {
        let clean = self.clean, summary = self.summary, summaryDelta = self.summaryDelta
        let server = StubServer { request in
            let (system, _) = Self.prompts(request, provider: provider)
            let output = system.contains("怎麼整理：") ? clean
                : system.contains("更新前次依人彙整") ? #"{"changes":[]}"#
                : system.contains("依說話者整理") ? #"{"digests":[]}"#
                : system.contains("只輸出異動") ? summaryDelta : summary
            return .status(200, provider == "gemini" ? Fixture.gemini(output) : Fixture.chatCompletion(output))
        }
        let recording: any LLMProvider
        if provider == "gemini" {
            recording = GeminiLLM(apiKey: "test", session: server.session).forRecording()
        } else {
            recording = OpenAICompatibleLLM(baseURL: URL(string: "http://stub.local/v1")!, apiKey: nil,
                                            model: "chosen-model", session: server.session).forRecording()
        }
        let generation = await recording.forGeneration()
        _ = try await generation.digestPerPerson(transcript)
        _ = try await generation.cleanTranscript(transcript)
        _ = try await generation.summarize(SummaryRequest(transcript: transcript, prioritized: []))
        #expect(server.requests.count == 3)
        #expect(!Self.prompts(server.requests[0], provider: provider).1.contains("辨識正規化參考（"))
        #expect(!Self.prompts(server.requests[2], provider: provider).1.contains("辨識正規化參考（"))
        let next = await recording.forGeneration()
        _ = try await next.digestPerPerson(transcript)
        _ = try await next.summarize(SummaryRequest(transcript: transcript, prioritized: []))
        #expect(server.requests.count == 5)
        #expect(server.requests.suffix(2).allSatisfy { Self.prompts($0, provider: provider).1.contains("10:30") })
    }

    private static func prompts(_ request: StubServer.Request, provider: String) -> (String, String) {
        if provider == "gemini" { return (request.geminiSystem, request.geminiInput) }
        let messages = request.json["messages"] as? [[String: Any]] ?? []
        return (messages.first?["content"] as? String ?? "", messages.last?["content"] as? String ?? "")
    }

    private actor HeldCleanup: StructuredGenerator {
        nonisolated let service = Service.gemini
        let clean: String
        let summary: String
        let summaryDelta: String
        var cleanupStarted = false
        var digestInputs: [String] = []
        var summaryInputs: [String] = []
        private var pending: CheckedContinuation<String, Never>?
        init(clean: String, summary: String, summaryDelta: String) {
            self.clean = clean; self.summary = summary; self.summaryDelta = summaryDelta
        }
        func generate(system: String, input: String, schema: JSON) async throws -> String {
            if system.contains("怎麼整理：") {
                cleanupStarted = true
                return await withCheckedContinuation { pending = $0 }
            }
            if system.contains("依說話者整理") {
                digestInputs.append(input)
                return system.contains("更新前次依人彙整") ? #"{"changes":[]}"# : #"{"digests":[]}"#
            }
            summaryInputs.append(input)
            return system.contains("只輸出異動") ? summaryDelta : summary
        }
        func release() { pending?.resume(returning: clean); pending = nil }
    }
}
