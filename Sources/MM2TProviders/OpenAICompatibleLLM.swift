import Foundation
import MM2TCore

/// The four LLM tasks on a self-hosted OpenAI-compatible server (vLLM, Ollama, LM Studio, llama.cpp):
/// `POST {baseURL}/chat/completions` with a JSON response format. The bearer token is optional.
public struct OpenAICompatibleLLM: LLMProvider, StructuredGenerator {
    public struct Limits: Sendable {
        /// Utterance text per cleaned-transcript request.
        public var cleanChunkCharacters: Int
        /// Transcript text sent whole to the other three tasks. Self-hosted models usually have a
        /// far smaller context window than a hosted one, so this stays well under 32k tokens.
        public var maxInputCharacters: Int
        public init(cleanChunkCharacters: Int = 2_000, maxInputCharacters: Int = 40_000) {
            self.cleanChunkCharacters = cleanChunkCharacters
            self.maxInputCharacters = maxInputCharacters
        }
    }

    let baseURL: URL
    let apiKey: Secret?
    let model: String
    let session: URLSession
    var limits: Limits
    let timeout: TimeInterval
    private let responseCache = StructuredResponseCache()
    private let rejectedFields = RejectedFields()
    private var summaryUpdates: SummaryCheckpointStore?
    private var digestUpdates: DigestCheckpointStore?
    private var cleanedCheckpoints: CleanedCheckpointStore?
    private var normalizationSnapshot: CleanedCheckpointStore.Snapshot?

    /// `baseURL` is the API root the user copies from their server, e.g. `http://host:8000/v1`.
    public init(
        baseURL: URL, apiKey: Secret?, model: String, session: URLSession = .shared,
        limits: Limits = Limits(), timeout: TimeInterval = 900
    ) {
        self.baseURL = Self.apiRoot(baseURL)
        self.apiKey = apiKey.flatMap { $0.isEmpty ? nil : $0 }
        self.model = model
        self.session = session
        self.limits = limits
        self.timeout = timeout
    }

    /// A bare server origin uses the standard /v1 API. Explicit paths are preserved for
    /// reverse proxies and nonstandard API roots; an existing /v1 is never appended twice.
    public static func apiRoot(_ url: URL) -> URL {
        url.path.isEmpty || url.path == "/" ? url.appending(path: "v1") : url
    }

    public enum ModelListingError: Error { case unsupported }

    /// Lists exact model IDs without running inference. The optional key stays in the header.
    public func availableModels() async throws -> [String] {
        var request = authorized(URLRequest(url: baseURL.appending(path: "models"), timeoutInterval: 15))
        request.httpMethod = "GET"
        let response = try await session.send(request, for: .openAICompatible)
        if response.status == 404 || response.status == 405 { throw ModelListingError.unsupported }
        guard response.status == 200 else { throw ProviderError(.openAICompatible, Self.failure(response)) }
        struct Listing: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: response.body) else {
            throw ProviderError(.openAICompatible, .malformedResponse)
        }
        return Set(listing.data.map(\.id).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).sorted()
    }

    // MARK: Tasks

    /// Recording checkpoints use shorter cleanup requests without changing the selected model.
    public func forRecording() -> Self {
        var recording = self
        recording.limits.cleanChunkCharacters = min(limits.cleanChunkCharacters, 300)
        recording.summaryUpdates = summaryUpdates ?? SummaryCheckpointStore()
        recording.digestUpdates = digestUpdates ?? DigestCheckpointStore()
        recording.cleanedCheckpoints = cleanedCheckpoints ?? CleanedCheckpointStore()
        return recording
    }

    public func forGeneration() async -> any LLMProvider {
        guard let cleanedCheckpoints else { return self }
        var generation = self
        generation.normalizationSnapshot = await cleanedCheckpoints.snapshot()
        return generation
    }

    private var tasks: LLMTasks {
        LLMTasks(self, cleanChunkCharacters: limits.cleanChunkCharacters, maxInputCharacters: limits.maxInputCharacters,
                 cleanConcurrency: 4, responseCache: responseCache, summaryUpdates: summaryUpdates, digestUpdates: digestUpdates,
                 cleanedCheckpoints: cleanedCheckpoints, normalizationSnapshot: normalizationSnapshot)
    }

    public func inferNames(_ request: NameInferenceRequest) async throws -> [NameGuess] { try await tasks.inferNames(request) }
    public func cleanTranscript(_ transcript: LLMTranscript) async throws -> CleanedTranscript { try await tasks.cleanTranscript(transcript) }
    public func digestPerPerson(_ transcript: LLMTranscript) async throws -> [PersonDigest] { try await tasks.digestPerPerson(transcript) }
    public func summarize(_ request: SummaryRequest) async throws -> Summary { try await tasks.summarize(request) }
    public func rewrite(_ text: String, instruction: String) async throws -> String { try await tasks.rewrite(text, instruction: instruction) }
    public func vocabularyCorrections(from old: String, to new: String) async throws -> [VocabularyCorrection] {
        try await tasks.vocabularyCorrections(from: old, to: new)
    }

    /// `GET /models` costs no tokens and checks the token. Servers without that route answer 404 or
    /// 405, so those get a one-token completion instead, which also proves the model name works.
    public func validateKey() async -> KeyCheck {
        do {
            var request = authorized(URLRequest(url: baseURL.appending(path: "models"), timeoutInterval: 30))
            request.httpMethod = "GET"
            var response = try await session.send(request, for: .openAICompatible)
            if response.status == 404 || response.status == 405 {
                let body = Self.object([
                    ("model", JSON.text(model).serialized()),
                    ("messages", JSON.list([Self.message("user", "ping")]).serialized()),
                    ("max_completion_tokens", "1"),
                ])
                response = try await session.send(completionRequest(body, timeout: 30), for: .openAICompatible)
            }
            if (200..<300).contains(response.status) { return .valid }
            return .from(ProviderError(.openAICompatible, Self.failure(response)))
        } catch let error as ProviderError {
            return .from(error)
        } catch {
            return .inconclusive(ProviderError(.openAICompatible, .unreachable).description)
        }
    }

    // MARK: Transport

    package var service: Service { .openAICompatible }

    package func generate(system: String, input: String, schema: JSON) async throws -> String {
        let preferred = try await send(system: system, input: input, format: Self.schemaFormat(schema))
        if preferred.status == 400 {
            // Not every server implements `json_schema`; `json_object` is the common denominator,
            // with the schema spelled out in the prompt instead.
            let hint = "\(system)\n\nReply with one JSON object that matches this JSON Schema:\n\(schema.serialized())"
            let fallback = try await send(system: hint, input: input, format: #"{"type":"json_object"}"#)
            guard fallback.status == 200 else { throw ProviderError(.openAICompatible, Self.failure(fallback)) }
            return try Self.messageText(fallback.body)
        }
        guard preferred.status == 200 else { throw ProviderError(.openAICompatible, Self.failure(preferred)) }
        return try Self.messageText(preferred.body)
    }

    /// `response_format` as serialized JSON.
    static func schemaFormat(_ schema: JSON) -> String {
        object([
            ("type", #""json_schema""#),
            ("json_schema", object([("name", #""result""#), ("schema", schema.serialized())])),
        ])
    }

    private func send(system: String, input: String, format: String) async throws -> HTTPResponse {
        var fields = chatFields(system: system, input: input, format: format)
        var response = try await session.send(
            completionRequest(Self.object(fields), timeout: timeout), for: .openAICompatible)
        // Optional extensions are not universal. Remove only explicitly rejected fields,
        // at most once each; never retry authentication, rate limits or server failures.
        for _ in 0..<3 {
            guard let accepted = withoutRejectedFields(fields, response) else { return response }
            fields = accepted
            response = try await session.send(
                completionRequest(Self.object(fields), timeout: timeout), for: .openAICompatible)
        }
        return response
    }

    /// One request shape for structured and streamed text, so hosted OpenAI and local servers get the
    /// same negotiation. `format` nil streams plain text.
    private func chatFields(system: String, input: String, format: String?) -> [(String, String)] {
        var fields: [(String, String)] = [
            ("model", JSON.text(model).serialized()),
            ("messages", JSON.list([Self.message("system", system), Self.message("user", input)]).serialized()),
        ]
        if let format { fields.append(("response_format", format)) }
        fields += [
            ("temperature", "0.2"),
            ("stream", format == nil ? "true" : "false"),
            // Bound runaway generation, including hidden reasoning. Truncation is already
            // handled by LLMTasks, which splits cleaned-transcript chunks when possible.
            // OpenAI's reasoning models reject the older `max_tokens`.
            ("max_completion_tokens", "8192"),
            // llama.cpp uses a separate thinking budget; effort alone may be ignored by
            // the template. Keep the total cap larger so the final answer has room.
            ("reasoning_effort", #""low""#),
            ("reasoning_budget_tokens", "512"),
        ]
        let rejected = rejectedFields.names
        return fields.filter { !rejected.contains($0.0) }
    }

    /// The fields left after removing every optional field this failure explicitly rejects, or nil
    /// when the failure is not such a rejection. Rejections are remembered, so later requests to the
    /// same server skip the extra round trips.
    private func withoutRejectedFields(_ fields: [(String, String)], _ response: HTTPResponse) -> [(String, String)]? {
        let rejected = fields.filter { Self.rejectsOptionalParameter($0.0, response) }.map(\.0)
        guard !rejected.isEmpty else { return nil }
        rejectedFields.insert(rejected)
        return fields.filter { !rejected.contains($0.0) }
    }

    /// Opens the event stream, negotiating optional fields exactly like `send`.
    func openStream(system: String, input: String) async throws -> URLSession.AsyncBytes {
        var fields = chatFields(system: system, input: input, format: nil)
        for attempt in 0...3 {
            let (bytes, status) = try await TextStreaming.connect(
                completionRequest(Self.object(fields), timeout: timeout), session: session, service: .openAICompatible)
            if status == 200 { return bytes }
            let failure = HTTPResponse(status: status, body: await TextStreaming.errorBody(bytes))
            guard attempt < 3, let accepted = withoutRejectedFields(fields, failure) else {
                throw ProviderError(.openAICompatible, Self.failure(failure))
            }
            fields = accepted
        }
        throw ProviderError(.openAICompatible, .serviceError)
    }

    private static func rejectsOptionalParameter(_ name: String, _ response: HTTPResponse) -> Bool {
        guard ["reasoning_effort", "reasoning_budget_tokens", "temperature"].contains(name),
              response.status == 400 || response.status == 422 else { return false }
        let error = String(decoding: response.body, as: UTF8.self).lowercased()
        return error.contains(name) &&
            ["unsupported", "not support", "unknown", "unrecognized", "extra",
             "invalid", "must be", "not permitted", "not allowed", "input should"].contains(where: error.contains)
    }

    /// `JSON` has no numbers or booleans, and the schema must keep its property order, so the
    /// request body is joined from already serialized values.
    private static func object(_ pairs: [(String, String)]) -> String {
        "{" + pairs.map { JSON.text($0.0).serialized() + ":" + $0.1 }.joined(separator: ",") + "}"
    }

    private static func message(_ role: String, _ content: String) -> JSON {
        .dict([("role", .text(role)), ("content", .text(content))])
    }

    private func completionRequest(_ body: String, timeout: TimeInterval) -> URLRequest {
        var request = authorized(URLRequest(url: baseURL.appending(path: "chat/completions"), timeoutInterval: timeout))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return request
    }

    private func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        if let apiKey { request.setValue("Bearer \(apiKey.revealed)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String?; let refusal: String? }
            let message: Message?
            let finish_reason: String?
        }
        let choices: [Choice]?
    }

    static func messageText(_ body: Data) throws -> String {
        guard let choice = (try? JSONDecoder().decode(Response.self, from: body))?.choices?.first else {
            throw ProviderError(.openAICompatible, .malformedResponse)
        }
        switch choice.finish_reason {
        case nil, "stop": break
        case "length": throw OutputTruncated()
        case "content_filter": throw ProviderError(.openAICompatible, .blocked)
        default: throw ProviderError(.openAICompatible, .malformedResponse)
        }
        if choice.message?.refusal?.isEmpty == false { throw ProviderError(.openAICompatible, .blocked) }
        let text = unwrapped(choice.message?.content ?? "")
        guard !text.isEmpty else { throw ProviderError(.openAICompatible, .malformedResponse) }
        return text
    }

    /// Local models often wrap the JSON in a reasoning block or a Markdown fence despite the format request.
    private static func unwrapped(_ content: String) -> String {
        var text = content
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
            if let fence = text.range(of: "```", options: .backwards) { text = String(text[..<fence.lowerBound]) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// A wrong base URL or model name answers 404; the model name is the usual culprit.
    static func failure(_ response: HTTPResponse) -> ProviderError.Kind {
        response.status == 404 ? .rejectedInput : response.commonFailure
    }
}

/// Optional request fields one server has explicitly rejected, shared by copies of a provider.
private final class RejectedFields: @unchecked Sendable {
    private let lock = NSLock()
    private var rejected: Set<String> = []
    var names: Set<String> { lock.withLock { rejected } }
    func insert(_ names: [String]) { lock.withLock { rejected.formUnion(names) } }
}
