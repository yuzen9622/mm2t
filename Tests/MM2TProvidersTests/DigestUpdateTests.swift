import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TProviders

@Suite struct DigestUpdateTests {
    private let initial = [
        utterance("u1", "r1", 0, "甲案是改用 Kubernetes；乙案是維持現況。目前先選乙案，明天由我通知客戶"),
        utterance("u2", "r2", 10, "預算上限仍是五十萬"),
    ]
    private let tail = [
        utterance("u3", "r1", 20, "恢復最開始甲案，明天通知客戶的工作取消，改由新同事寫內部報告"),
        utterance("u4", "r3", 25, "我接下內部報告，週五前完成"),
    ]
    private let early = #"{"digests":[{"speaker":"r1","points":[{"text":"目前選乙案維持現況","sources":["u1"]},{"text":"明天通知客戶","sources":["u1"]}]},{"speaker":"r2","points":[{"text":"預算上限五十萬","sources":["u2"]}]}]}"#
    private let fallback = #"{"digests":[{"speaker":"r1","points":[{"text":"完整重算後改採甲案","sources":["u1","u3"]}]}]}"#
    private let delta = #"{"changes":[{"speaker":"r3","remove":[],"replace":[],"append":[{"text":"週五前完成內部報告","sources":["u3","u4"]}]},{"speaker":"r1","remove":[1],"replace":[{"index":0,"item":{"text":"{{speaker:r1}}：恢復甲案，改用 Kubernetes","sources":["u1","u3"]}}],"append":[]}]}"#

    @Test func lateReversalReplacesTheOldPositionAndAddsANewSpeakerWithoutRepeatingUnchangedPoints() async throws {
        let early = self.early, delta = self.delta
        let server = StubServer { request in
            .status(200, Fixture.gemini(request.geminiSystem.contains("更新前次依人彙整") ? delta : early))
        }
        let llm = GeminiLLM(apiKey: "test", session: server.session).forRecording()
        _ = try await llm.digestPerPerson(LLMTranscript(utterances: initial))
        let transcript = LLMTranscript(utterances: initial + tail)
        let final = try await llm.digestPerPerson(transcript)
        #expect(final.map(\.speaker) == ["r1", "r2", "r3"].map(SpeakerID.init))
        #expect(final[0].points == [SourcedText(text: "恢復甲案，改用 Kubernetes", sources: [UtteranceID("u1"), UtteranceID("u3")])])
        #expect(final[1].points == [SourcedText(text: "預算上限五十萬", sources: [UtteranceID("u2")])])
        #expect(final[2].points == [SourcedText(text: "週五前完成內部報告", sources: [UtteranceID("u3"), UtteranceID("u4")])])
        #expect(server.requests.count == 2)
        let update = try #require(server.requests.last)
        #expect((initial + tail).allSatisfy { update.geminiInput.contains($0.text) })
        #expect(update.geminiInput.contains("前次依人彙整") && update.geminiInput.contains("新增尾段"))
        #expect(update.geminiInput.contains(#""index":1"#))
        #expect(try await llm.forRecording().digestPerPerson(transcript) == final)
        #expect(server.requests.count == 2)
    }

    @Test(arguments: ["duplicateSpeaker", "unknownSpeaker", "duplicateRemove", "duplicateReplace", "duplicateAppend", "overlap", "negative", "outOfRange", "emptySources", "inventedSource", "duplicateSources", "emptyText", "newSpeakerReplace"])
    func malformedChangesFallBackToTheFullTranscript(_ fault: String) async throws {
        var point: [String: Any] = ["text": fault == "emptyText" ? " \n " : "恢復甲案", "sources": ["u1", "u3"]]
        if fault == "emptySources" { point["sources"] = [String]() }
        if fault == "inventedSource" { point["sources"] = ["u999"] }
        if fault == "duplicateSources" { point["sources"] = ["u1", "u1"] }
        let index = fault == "negative" ? -1 : fault == "outOfRange" ? 2 : 0
        let replacement: [String: Any] = ["index": index, "item": point]
        let change: [String: Any] = [
            "speaker": fault == "unknownSpeaker" ? "r999" : fault == "newSpeakerReplace" ? "r3" : "r1",
            "remove": fault == "duplicateRemove" ? [1, 1] : fault == "overlap" ? [0] : [],
            "replace": fault == "duplicateReplace" ? [replacement, replacement] : [replacement],
            "append": fault == "duplicateAppend" ? [point, point] : [],
        ]
        let changes = fault == "duplicateSpeaker" ? [change, change] : [change]
        let malformed = String(decoding: try JSONSerialization.data(withJSONObject: ["changes": changes]), as: UTF8.self)
        let early = self.early, fallback = self.fallback
        let server = StubServer { request in
            let result = request.geminiSystem.contains("更新前次依人彙整") ? malformed
                : request.geminiInput.contains("[u3]") ? fallback : early
            return .status(200, Fixture.gemini(result))
        }
        let llm = GeminiLLM(apiKey: "test", session: server.session).forRecording()
        _ = try await llm.digestPerPerson(LLMTranscript(utterances: initial))
        let transcript = LLMTranscript(utterances: initial + tail)
        let final = try await llm.digestPerPerson(transcript)
        #expect(final.first?.points.first?.text == "完整重算後改採甲案")
        #expect(server.requests.count == 3)
        #expect(server.requests[1].geminiSystem.contains("更新前次依人彙整"))
        #expect(!server.requests[2].geminiSystem.contains("更新前次依人彙整"))
        #expect((initial + tail).allSatisfy { server.requests[2].geminiInput.contains($0.text) })
        #expect(try await llm.digestPerPerson(transcript) == final)
        #expect(server.requests.count == 3)
    }

    @Test(arguments: ["speaker", "id", "text", "time", "highlight", "glossary", "merge"])
    func changedSourcesOrSpeakerAssignmentsRequireFullGeneration(_ field: String) async throws {
        let server = StubServer(status: 200, body: Fixture.gemini(#"{"digests":[]}"#))
        let llm = GeminiLLM(apiKey: "test", session: server.session).forRecording()
        _ = try await llm.digestPerPerson(LLMTranscript(utterances: initial))
        var modified = initial
        modified[0] = utterance(field == "id" ? "new-id" : "u1", field == "speaker" ? "r2" : "r1",
                                field == "time" ? 1 : 0, field == "text" ? "修正原文" : initial[0].text,
                                highlighted: field == "highlight")
        if field == "merge" { modified.removeLast() }
        var transcript = LLMTranscript(utterances: modified + tail)
        if field == "glossary" { transcript.glossary = ["Kubernetes"] }
        _ = try await llm.digestPerPerson(transcript)
        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy { !$0.geminiSystem.contains("更新前次依人彙整") })
    }

    @Test func outputLanguageChangesRequireFullGeneration() async throws {
        let server = StubServer(status: 200, body: Fixture.gemini(#"{"digests":[]}"#))
        let llm = GeminiLLM(apiKey: "test", session: server.session).forRecording()
        let first = [utterance("u1", "r1", 0, "同意")]
        _ = try await llm.digestPerPerson(LLMTranscript(utterances: first))
        let english = utterance("u2", "r1", 5, String(repeating: "English discussion content ", count: 50))
        _ = try await llm.digestPerPerson(LLMTranscript(utterances: first + [english]))
        #expect(server.requests.count == 2)
        #expect(server.requests.last?.geminiSystem.contains("Output language: English") == true)
        #expect(server.requests.allSatisfy { !$0.geminiSystem.contains("更新前次依人彙整") })
    }

    @Test(arguments: ["authentication", "network"])
    func serviceFailuresAreNotRetriedAsFullGeneration(_ failure: String) async throws {
        let early = self.early
        let server = StubServer { request in
            if request.geminiSystem.contains("更新前次依人彙整") {
                return failure == "authentication" ? .status(401, "{}") : .failure(.notConnectedToInternet)
            }
            return .status(200, Fixture.gemini(early))
        }
        let llm = GeminiLLM(apiKey: "test", session: server.session).forRecording()
        _ = try await llm.digestPerPerson(LLMTranscript(utterances: initial))
        let error = ProviderError(.gemini, failure == "authentication" ? .invalidCredential : .unreachable)
        await #expect(throws: error) { try await llm.digestPerPerson(LLMTranscript(utterances: initial + tail)) }
        #expect(server.requests.count == 2)
    }

    @Test func failedFallbackDoesNotReturnTheOldDigestAsACompletedResult() async throws {
        let early = self.early
        let server = StubServer { request in
            if request.geminiSystem.contains("更新前次依人彙整") { return .status(200, Fixture.gemini(#"{"changes":"invalid"}"#)) }
            if request.geminiInput.contains("[u3]") { return .status(401, "{}") }
            return .status(200, Fixture.gemini(early))
        }
        let llm = GeminiLLM(apiKey: "test", session: server.session).forRecording()
        _ = try await llm.digestPerPerson(LLMTranscript(utterances: initial))
        await #expect(throws: ProviderError(.gemini, .invalidCredential)) {
            try await llm.digestPerPerson(LLMTranscript(utterances: initial + tail))
        }
        #expect(server.requests.count == 3)
    }

    @Test func nonRecordingRequestsContinueToGenerateTheFullDigest() async throws {
        let early = self.early
        let server = StubServer(status: 200, body: Fixture.gemini(early))
        let llm = GeminiLLM(apiKey: "test", session: server.session)
        _ = try await llm.digestPerPerson(LLMTranscript(utterances: initial))
        _ = try await llm.digestPerPerson(LLMTranscript(utterances: initial + tail))
        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy { !$0.geminiSystem.contains("更新前次依人彙整") })
    }

    @Test func openAICompatibleRecordingSharesTheSameIncrementalBehavior() async throws {
        let early = self.early, delta = self.delta
        let server = StubServer { request in
            let messages = request.json["messages"] as? [[String: Any]]
            let system = messages?.first?["content"] as? String ?? ""
            return .status(200, Fixture.chatCompletion(system.contains("更新前次依人彙整") ? delta : early))
        }
        let llm = OpenAICompatibleLLM(baseURL: URL(string: "http://stub.local/v1")!, apiKey: nil,
                                     model: "chosen-model", session: server.session).forRecording()
        _ = try await llm.digestPerPerson(LLMTranscript(utterances: initial))
        let final = try await llm.digestPerPerson(LLMTranscript(utterances: initial + tail))
        #expect(final.map(\.speaker) == ["r1", "r2", "r3"].map(SpeakerID.init))
        #expect(final[0].points.count == 1)
        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy { $0.json["model"] as? String == "chosen-model" })
    }

    @Test func olderAsyncCompletionCannotReplaceANewerCheckpoint() async {
        let store = DigestCheckpointStore()
        let old = await store.begin()
        let newer = await store.begin()
        let oldDigests = [PersonDigest(speaker: SpeakerID("r1"), points: [SourcedText(text: "old", sources: [UtteranceID("u1")])])]
        let newDigests = [PersonDigest(speaker: SpeakerID("r1"), points: [SourcedText(text: "new", sources: [UtteranceID("u3")])])]
        await store.accept(newDigests, for: LLMTranscript(utterances: initial + tail), ticket: newer)
        await store.accept(oldDigests, for: LLMTranscript(utterances: initial), ticket: old)
        let current = await store.begin()
        #expect(current.previous?.digests == newDigests)
        #expect(current.previous?.transcript.utterances.count == 4)
        await store.accept(oldDigests, for: LLMTranscript(utterances: initial), ticket: current)
        #expect(await store.begin().previous?.digests == newDigests)
    }
}
