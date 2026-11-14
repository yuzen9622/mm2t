import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TProviders

extension Fixture {
    /// A chat completion whose single choice carries `content`.
    static func chatCompletion(_ content: String, finishReason: String = "stop", refusal: String? = nil) -> String {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: content, options: .fragmentsAllowed), as: UTF8.self)
        let refused = refusal.map { #","refusal":"\#($0)""# } ?? ""
        return """
        {"id":"chatcmpl-1","object":"chat.completion","model":"qwen3",
         "choices":[{"index":0,"message":{"role":"assistant","content":\(text)\(refused)},"finish_reason":"\(finishReason)"}],
         "usage":{"prompt_tokens":812,"completion_tokens":95,"total_tokens":907}}
        """
    }
}

@Suite struct OpenAICompatibleLLMTests {
    let base = URL(string: "http://gpu.local:8000/v1")!
    let transcript = LLMTranscript(utterances: [
        utterance("u1", "me", 0, "嗯那個我們今天要討論 Kubernetes 的 migration"),
        utterance("u2", "r1", 5, "禮拜四之前要先把 cluster 升級"),
    ])

    func llm(_ server: StubServer, key: Secret? = "sk-local") -> OpenAICompatibleLLM {
        OpenAICompatibleLLM(baseURL: base, apiKey: key, model: "qwen3", session: server.session)
    }

    @Test func postsAJSONSchemaChatCompletionWithTheBearerToken() async throws {
        let server = StubServer(status: 200, body: Fixture.chatCompletion(#"{"paragraphs":[]}"#))
        _ = try await llm(server).cleanTranscript(transcript)

        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "http://gpu.local:8000/v1/chat/completions")
        #expect(request.headers["Authorization"] == "Bearer sk-local")
        #expect(request.json["model"] as? String == "qwen3")
        let messages = try #require(request.json["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect((messages[1]["content"] as? String)?.contains("u1") == true)
        let format = try #require(request.json["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require((format["json_schema"] as? [String: Any])?["schema"] as? [String: Any])
        let items = ((schema["properties"] as? [String: Any])?["paragraphs"] as? [String: Any])?["items"] as? [String: Any]
        let speaker = (items?["properties"] as? [String: Any])?["speaker"] as? [String: Any]
        #expect(speaker?["enum"] as? [String] == ["me", "r1"])
    }

    @Test func boundsGenerationAndRequestsLowReasoningByDefault() async throws {
        let server = StubServer(status: 200, body: Fixture.chatCompletion(#"{"paragraphs":[]}"#))
        _ = try await llm(server).cleanTranscript(transcript)
        let request = try #require(server.requests.first)
        #expect(request.json["max_tokens"] as? Int == 8192)
        #expect(request.json["chat_template_kwargs"] == nil)
        #expect(request.json["reasoning_effort"] as? String == "low")
        #expect(request.json["reasoning_budget_tokens"] as? Int == 512)
    }

    @Test func requestsLowReasoningForArbitraryModelAliases() async throws {
        let server = StubServer(status: 200, body: Fixture.chatCompletion(#"{"paragraphs":[]}"#))
        let provider = OpenAICompatibleLLM(baseURL: base, apiKey: nil, model: "llama", session: server.session)
        _ = try await provider.cleanTranscript(transcript)
        let request = try #require(server.requests.first)
        #expect(request.json["max_tokens"] as? Int == 8192)
        #expect(request.json["chat_template_kwargs"] == nil)
        #expect(request.json["reasoning_effort"] as? String == "low")
        #expect(request.json["reasoning_budget_tokens"] as? Int == 512)
    }

    @Test(arguments: [400, 422]) func dropsExplicitlyRejectedReasoningEffort(status: Int) async throws {
        let server = StubServer { request in
            if request.json["reasoning_effort"] != nil {
                return .status(status, #"{"error":{"message":"Unsupported parameter: reasoning_effort"}}"#)
            }
            return .status(200, Fixture.chatCompletion(#"{"paragraphs":[]}"#))
        }
        _ = try await llm(server).cleanTranscript(transcript)
        #expect(server.requests.count == 2)
        #expect(server.requests[1].json["reasoning_effort"] == nil)
        #expect(server.requests.allSatisfy { $0.json["max_tokens"] as? Int == 8192 })
        #expect(server.requests.allSatisfy { $0.json["chat_template_kwargs"] == nil })
        #expect(server.requests.allSatisfy {
            ($0.json["response_format"] as? [String: Any])?["type"] as? String == "json_schema"
        })
    }

    @Test(arguments: [400, 422]) func dropsOnlyExplicitlyRejectedBudget(status: Int) async throws {
        let server = StubServer { request in
            if request.json["reasoning_budget_tokens"] != nil {
                return .status(status, #"{"error":{"message":"Unknown parameter: reasoning_budget_tokens"}}"#)
            }
            return .status(200, Fixture.chatCompletion(#"{"paragraphs":[]}"#))
        }
        _ = try await llm(server).cleanTranscript(transcript)
        #expect(server.requests.count == 2)
        #expect(server.requests[1].json["reasoning_budget_tokens"] == nil)
        #expect(server.requests[1].json["reasoning_effort"] as? String == "low")
        #expect(server.requests[1].json["max_tokens"] as? Int == 8192)
    }

    @Test func dropsBothOptionalFieldsWhenRejectedSequentially() async throws {
        let server = StubServer { request in
            for field in ["reasoning_budget_tokens", "reasoning_effort"] where request.json[field] != nil {
                return .status(422, "{\"error\":{\"message\":\"Unsupported parameter: \(field)\"}}")
            }
            return .status(200, Fixture.chatCompletion(#"{"paragraphs":[]}"#))
        }
        _ = try await llm(server).cleanTranscript(transcript)
        #expect(server.requests.count == 3)
        #expect(server.requests[2].json["max_tokens"] as? Int == 8192)
    }

    @Test func doesNotRetryServerFailureMentioningReasoning() async throws {
        let server = StubServer(status: 503, body: #"{"error":{"message":"invalid reasoning_effort"}}"#)
        await #expect(throws: ProviderError(.openAICompatible, .unavailable)) {
            try await llm(server).cleanTranscript(transcript)
        }
        #expect(server.requests.count == 1)
    }

    @Test func aTrailingSlashAndAMissingTokenAreFine() async throws {
        let server = StubServer(status: 200, body: Fixture.chatCompletion(#"{"paragraphs":[]}"#))
        let provider = OpenAICompatibleLLM(
            baseURL: URL(string: "http://gpu.local:8000/v1/")!, apiKey: Secret(""), model: "qwen3", session: server.session)
        _ = try await provider.cleanTranscript(transcript)
        let request = try #require(server.requests.first)
        #expect(request.url.absoluteString == "http://gpu.local:8000/v1/chat/completions")
        #expect(request.headers["Authorization"] == nil)
    }

    @Test func fallsBackToJSONObjectWhenTheServerRejectsJSONSchema() async throws {
        let server = StubServer { request in
            let format = (request.json["response_format"] as? [String: Any])?["type"] as? String
            return format == "json_schema"
                ? .status(400, #"{"error":{"message":"response_format json_schema is not supported"}}"#)
                : .status(200, Fixture.chatCompletion(#"{"paragraphs":[]}"#))
        }
        let cleaned = try await llm(server).cleanTranscript(transcript)
        #expect(cleaned.paragraphs.isEmpty)
        #expect(server.requests.count == 2)
        let retry = try #require(server.requests.last)
        #expect((retry.json["response_format"] as? [String: Any])?["type"] as? String == "json_object")
        let system = ((retry.json["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        #expect(system.contains("JSON Schema") && system.contains("\"paragraphs\""))
    }

    @Test func readsJSONFromFencesAndReasoningBlocks() throws {
        let fenced = Fixture.chatCompletion("```json\n{\"a\":1}\n```")
        #expect(try OpenAICompatibleLLM.messageText(Data(fenced.utf8)) == #"{"a":1}"#)
        let thinking = Fixture.chatCompletion("<think>hmm</think>\n{\"a\":2}")
        #expect(try OpenAICompatibleLLM.messageText(Data(thinking.utf8)) == #"{"a":2}"#)
    }

    @Test func mapsFinishReasonsAndBadBodies() throws {
        #expect(throws: OutputTruncated.self) {
            try OpenAICompatibleLLM.messageText(Data(Fixture.chatCompletion("{", finishReason: "length").utf8))
        }
        #expect(throws: ProviderError(.openAICompatible, .blocked)) {
            try OpenAICompatibleLLM.messageText(Data(Fixture.chatCompletion("", finishReason: "content_filter").utf8))
        }
        #expect(throws: ProviderError(.openAICompatible, .blocked)) {
            try OpenAICompatibleLLM.messageText(Data(Fixture.chatCompletion("", refusal: "no").utf8))
        }
        #expect(throws: ProviderError(.openAICompatible, .malformedResponse)) {
            try OpenAICompatibleLLM.messageText(Data(#"{"choices":[]}"#.utf8))
        }
        #expect(throws: ProviderError(.openAICompatible, .malformedResponse)) {
            try OpenAICompatibleLLM.messageText(Data("<html>".utf8))
        }
    }

    @Test func httpFailuresAreMappedWithoutLeakingTheToken() async throws {
        for (status, kind) in [(401, ProviderError.Kind.invalidCredential), (404, .rejectedInput), (429, .rateLimited), (503, .unavailable)] {
            let server = StubServer(status: status, body: #"{"error":{"message":"sk-local nope"}}"#)
            let error = await #expect(throws: ProviderError.self) { try await llm(server).cleanTranscript(transcript) }
            #expect(error == ProviderError(.openAICompatible, kind))
            #expect(!allMessages(of: error!).contains("sk-local"))
        }
    }

    @Test func offlineServerIsUnreachable() async throws {
        let server = StubServer { _ in .failure(.cannotConnectToHost) }
        await #expect(throws: ProviderError(.openAICompatible, .unreachable)) { try await llm(server).cleanTranscript(transcript) }
    }

    @Test func validateKeyUsesModelsThenFallsBackToACompletion() async throws {
        let ok = StubServer(status: 200, body: #"{"data":[]}"#)
        #expect(await llm(ok).validateKey() == .valid)
        #expect(ok.requests.map(\.url.path) == ["/v1/models"])
        #expect(ok.requests.first?.headers["Authorization"] == "Bearer sk-local")

        let bad = StubServer(status: 401, body: "{}")
        guard case .rejected = await llm(bad).validateKey() else { Issue.record("expected rejected"); return }

        let noModels = StubServer { request in
            request.url.path.hasSuffix("/models") ? .status(404, "{}") : .status(200, Fixture.chatCompletion("pong"))
        }
        #expect(await llm(noModels).validateKey() == .valid)
        #expect(noModels.requests.map(\.url.path) == ["/v1/models", "/v1/chat/completions"])
        #expect(noModels.requests.last?.json["max_tokens"] as? Int == 1)

        let offline = StubServer { _ in .failure(.timedOut) }
        guard case .inconclusive = await llm(offline).validateKey() else { Issue.record("expected inconclusive"); return }
    }
}
