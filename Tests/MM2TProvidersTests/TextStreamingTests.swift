import Foundation
import MM2TCore
import Testing
@testable import MM2TProviders

@Suite(.serialized) struct TextStreamingTests {
    // Recorded wire shapes from the vendors' streaming examples, with UTF-8 text substituted.
    private let gemini = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"你好\"}],\"role\":\"model\"}}]}\r\n\r\ndata: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"世界\"}]},\"finishReason\":\"STOP\"}]}\n\n"
    private let openAI = "data: {\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"你好世界\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"

    @Test func parsesEveryByteBoundaryInBothFormats() throws {
        for (wire, format) in [(gemini, TextStreaming.Format.gemini), (openAI, .openAI)] {
            let data = Data(wire.utf8)
            for split in 0...data.count {
                var parser = SSEParser()
                let events = parser.append(Data(data.prefix(split))) + parser.append(Data(data.dropFirst(split)))
                var text = ""
                for event in events {
                    if case .text(let delta) = try TextStreaming.decode(event, format: format) { text += delta }
                }
                #expect(text == "你好世界")
            }
        }
    }

    @Test func realProviderRequestsAndTextDeltas() async throws {
        let google = StubServer(status: 200, body: gemini)
        var text = ""
        for try await delta in GeminiLLM(apiKey: Secret("test"), session: google.session).streamText(system: "System", input: "Question") { text += delta }
        #expect(text == "你好世界")
        #expect(google.requests.first?.url.query == "alt=sse")
        #expect(google.requests.first?.url.path.hasSuffix(":streamGenerateContent") == true)
        let server = StubServer(status: 200, body: openAI)
        let provider = OpenAICompatibleLLM(baseURL: URL(string: "https://example.test/v1")!, apiKey: nil, model: "test", session: server.session)
        text = ""
        for try await delta in provider.streamText(system: "System", input: "Question") { text += delta }
        #expect(text == "你好世界")
        let body = try JSONSerialization.jsonObject(with: #require(server.requests.first?.body)) as? [String: Any]
        #expect(body?["stream"] as? Bool == true)
        #expect(body?["response_format"] == nil)
    }

    @Test func openAIStreamingUsesCurrentTokenLimitAndDropsRejectedOptionalFields() async throws {
        let wire = openAI
        let server = StubServer { request in
            if request.json["max_tokens"] != nil {
                return .status(400, #"{"error":{"message":"Unsupported parameter: 'max_tokens' is not supported with this model."}}"#)
            }
            for field in ["reasoning_budget_tokens", "temperature"] where request.json[field] != nil {
                return .status(400, "{\"error\":{\"message\":\"Unrecognized request argument supplied: \(field)\"}}")
            }
            return .status(200, wire)
        }
        let provider = OpenAICompatibleLLM(baseURL: URL(string: "https://example.test/v1")!, apiKey: nil, model: "test", session: server.session)
        var text = ""
        for try await delta in provider.streamText(system: "System", input: "Question") { text += delta }
        #expect(text == "你好世界")
        #expect(server.requests.count == 3)
        #expect(server.requests.allSatisfy { $0.json["max_completion_tokens"] as? Int == 8192 && $0.json["stream"] as? Bool == true })
        #expect(server.requests.last?.json["reasoning_effort"] as? String == "low")
    }

    @Test func openAIStreamingReportsTheServersFailure() async throws {
        let server = StubServer(status: 401, body: #"{"error":{"message":"Incorrect API key provided"}}"#)
        let provider = OpenAICompatibleLLM(baseURL: URL(string: "https://example.test/v1")!, apiKey: "bad", model: "test", session: server.session)
        await #expect(throws: ProviderError(.openAICompatible, .invalidCredential)) {
            for try await _ in provider.streamText(system: "", input: "") {}
        }
        #expect(server.requests.count == 1)
    }

    @Test func rejectsBlockedAndTruncatedChunks() throws {
        #expect(throws: (any Error).self) {
            try TextStreaming.decode(#"{"candidates":[{"finishReason":"MAX_TOKENS"}]}"#, format: .gemini)
        }
        #expect(throws: (any Error).self) {
            try TextStreaming.decode(#"{"choices":[{"delta":{"refusal":"No"}}]}"#, format: .openAI)
        }
    }

    @Test func defaultFallbackYieldsOnce() async throws {
        var chunks: [String] = []
        for try await delta in FallbackLLM().streamText(system: "instruction", input: "input") { chunks.append(delta) }
        #expect(chunks == ["instruction|input"])
    }

    @Test(arguments: [true, false]) func consumingTaskCancellationStopsNetwork(gemini: Bool) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingStreamProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        HangingStreamProtocol.reset()
        let provider: any LLMProvider = gemini
            ? GeminiLLM(apiKey: Secret("test"), session: session)
            : OpenAICompatibleLLM(baseURL: URL(string: "https://example.test/v1")!, apiKey: nil, model: "test", session: session)
        let task = Task {
            for try await _ in provider.streamText(system: "", input: "") {}
        }
        for _ in 0..<500 where !HangingStreamProtocol.started { try await Task.sleep(for: .milliseconds(2)) }
        #expect(HangingStreamProtocol.started)
        #expect(!HangingStreamProtocol.stopped)
        task.cancel()
        _ = await task.result
        for _ in 0..<500 where !HangingStreamProtocol.stopped { try await Task.sleep(for: .milliseconds(2)) }
        #expect(HangingStreamProtocol.stopped)
    }
}

private struct FallbackLLM: LLMProvider {
    func generateText(system: String, input: String) async throws -> String { system + "|" + input }
    func inferNames(_ request: NameInferenceRequest) async throws -> [NameGuess] { [] }
    func cleanTranscript(_ transcript: LLMTranscript) async throws -> CleanedTranscript { .init(paragraphs: []) }
    func digestPerPerson(_ transcript: LLMTranscript) async throws -> [PersonDigest] { [] }
    func summarize(_ request: SummaryRequest) async throws -> Summary { .init(decisions: [], discussionPoints: [], actionItems: []) }
}

private final class HangingStreamProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var didStart = false
    nonisolated(unsafe) private static var didStop = false
    static var started: Bool { lock.withLock { didStart } }
    static var stopped: Bool { lock.withLock { didStop } }
    static func reset() { lock.withLock { didStart = false; didStop = false } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.didStart = true }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(": keepalive\n\n".utf8))
    }
    override func stopLoading() { Self.lock.withLock { Self.didStop = true } }
}
