import Foundation
import MM2TCore

/// The four LLM tasks on Gemini `generateContent` with JSON-schema structured output.
/// Docs: https://aistudio.google.com/docs/structured-output?generate-content=true
public struct GeminiLLM: LLMProvider, StructuredGenerator {
    public static let defaultModel = "gemini-3.8-flash"
    static let base = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/")!

    public struct Limits: Sendable {
        /// Utterance text per cleaned-transcript request. The cleaned transcript is as long as its
        /// input, so the 65,536-token output cap, not the 1M input window, is what forces chunking.
        public var cleanChunkCharacters: Int
        /// Transcript text sent whole to the other three tasks; well inside the 1,048,576-token input window.
        public var maxInputCharacters: Int
        public init(cleanChunkCharacters: Int = 6_000, maxInputCharacters: Int = 600_000) {
            self.cleanChunkCharacters = cleanChunkCharacters
            self.maxInputCharacters = maxInputCharacters
        }
    }

    let apiKey: Secret
    let model: String
    let session: URLSession
    let limits: Limits
    let timeout: TimeInterval

    public init(
        apiKey: Secret, model: String = GeminiLLM.defaultModel, session: URLSession = .shared,
        limits: Limits = Limits(), timeout: TimeInterval = 600
    ) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.limits = limits
        self.timeout = timeout
    }

    // MARK: Tasks

    private var tasks: LLMTasks {
        LLMTasks(self, cleanChunkCharacters: limits.cleanChunkCharacters, maxInputCharacters: limits.maxInputCharacters, cleanConcurrency: 4)
    }

    public func inferNames(_ request: NameInferenceRequest) async throws -> [NameGuess] { try await tasks.inferNames(request) }
    public func cleanTranscript(_ transcript: LLMTranscript) async throws -> CleanedTranscript { try await tasks.cleanTranscript(transcript) }
    public func digestPerPerson(_ transcript: LLMTranscript) async throws -> [PersonDigest] { try await tasks.digestPerPerson(transcript) }
    public func summarize(_ request: SummaryRequest) async throws -> Summary { try await tasks.summarize(request) }

    /// `models.get` costs no tokens and fails the same way a real request would on a bad key.
    public func validateKey() async -> KeyCheck {
        var request = URLRequest(url: Self.base.appending(path: model), timeoutInterval: 30)
        request.setValue(apiKey.revealed, forHTTPHeaderField: "x-goog-api-key")
        do {
            let response = try await session.send(request, for: .gemini)
            if response.status == 200 { return .valid }
            return .from(ProviderError(.gemini, Self.failure(response)))
        } catch let error as ProviderError {
            return .from(error)
        } catch {
            return .inconclusive(ProviderError(.gemini, .unreachable).description)
        }
    }

    // MARK: Transport

    package var service: Service { .gemini }

    package func generate(system: String, input: String, schema: JSON) async throws -> String {
        let body = JSON.dict([
            ("systemInstruction", .dict([("parts", .list([.dict([("text", .text(system))])]))])),
            ("contents", .list([.dict([
                ("role", .text("user")),
                ("parts", .list([.dict([("text", .text(input))])])),
            ])])),
            ("generationConfig", .dict([
                ("responseMimeType", .text("application/json")),
                ("responseJsonSchema", schema),
            ])),
        ])
        var request = URLRequest(url: Self.base.appending(path: "\(model):generateContent"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(apiKey.revealed, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.serialized().utf8)

        let response = try await session.send(request, for: .gemini)
        guard response.status == 200 else { throw ProviderError(.gemini, Self.failure(response)) }
        return try Self.candidateText(response.body)
    }

    private struct Response: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable { let parts: [Part]? }
            struct Part: Decodable { let text: String?; let thought: Bool? }
            let content: Content?
            let finishReason: String?
        }
        struct Feedback: Decodable { let blockReason: String? }
        let candidates: [Candidate]?
        let promptFeedback: Feedback?
    }

    static func candidateText(_ body: Data) throws -> String {
        guard let response = try? JSONDecoder().decode(Response.self, from: body) else {
            throw ProviderError(.gemini, .malformedResponse)
        }
        if response.promptFeedback?.blockReason != nil { throw ProviderError(.gemini, .blocked) }
        guard let candidate = response.candidates?.first else { throw ProviderError(.gemini, .malformedResponse) }
        switch candidate.finishReason {
        case nil, "STOP": break
        case "MAX_TOKENS": throw OutputTruncated()
        case "SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION": throw ProviderError(.gemini, .blocked)
        default: throw ProviderError(.gemini, .malformedResponse)
        }
        let text = (candidate.content?.parts ?? []).filter { $0.thought != true }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw ProviderError(.gemini, .malformedResponse) }
        return text
    }

    /// Google reports a bad key as 400 INVALID_ARGUMENT with reason API_KEY_INVALID on
    /// generateContent, and as 401 per the current error table; both mean the same to the user.
    static func failure(_ response: HTTPResponse) -> ProviderError.Kind {
        let error = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["error"] as? [String: Any]
        let status = (error?["status"] as? String) ?? (error?["code"] as? String) ?? ""
        let reasons = (error?["details"] as? [[String: Any]] ?? []).compactMap { $0["reason"] as? String }
        let message = (error?["message"] as? String ?? "").lowercased()
        if reasons.contains("API_KEY_INVALID") || (response.status == 400 && message.contains("api key")) {
            return .invalidCredential
        }
        if status == "FAILED_PRECONDITION" || status == "failed_precondition" { return .permissionDenied }
        if status == "payment_required" { return .outOfCredit }
        return response.commonFailure
    }
}
