import Foundation
import MM2TCore

/// The four LLM tasks on Gemini `generateContent` with JSON-schema structured output.
/// Docs: https://aistudio.google.com/docs/structured-output?generate-content=true
public struct GeminiLLM: LLMProvider {
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

    public func inferNames(_ request: NameInferenceRequest) async throws -> [NameGuess] {
        guard !request.unnamedSpeakers.isEmpty, !request.transcript.utterances.isEmpty else { return [] }
        try checkLength(request.transcript.utterances)
        struct Output: Decodable {
            struct Guess: Decodable { let speaker: String; let name: String; let reason: String }
            let guesses: [Guess]
        }
        let output = try await whole(
            Output.self, task: GeminiPrompts.inferNames, input: GeminiPrompts.nameRequest(request),
            schema: GeminiPrompts.nameSchema(request.unnamedSpeakers))
        let unnamed = Set(request.unnamedSpeakers)
        return output.guesses.compactMap { guess in
            let name = guess.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let speaker = SpeakerID(guess.speaker)
            guard unnamed.contains(speaker), !name.isEmpty else { return nil }
            return NameGuess(speaker: speaker, name: name, reason: guess.reason)
        }
    }

    /// Cleans the transcript in chunks of whole utterances, because the output is as long as the input.
    /// A chunk whose output still hits the token cap is split in half and retried.
    public func cleanTranscript(_ transcript: LLMTranscript) async throws -> CleanedTranscript {
        var paragraphs: [CleanedTranscript.Paragraph] = []
        for chunk in Self.chunks(transcript.utterances, maxCharacters: limits.cleanChunkCharacters) {
            paragraphs += try await clean(chunk)
        }
        return CleanedTranscript(paragraphs: paragraphs)
    }

    private func clean(_ chunk: [LLMUtterance]) async throws -> [CleanedTranscript.Paragraph] {
        struct Output: Decodable {
            struct Paragraph: Decodable { let speaker: String; let text: String; let sources: [String] }
            let paragraphs: [Paragraph]
        }
        let speakers = Self.speakers(in: chunk)
        do {
            let output = try await generate(
                Output.self, task: GeminiPrompts.cleanTranscript,
                input: "逐字稿：\n" + GeminiPrompts.render(chunk), schema: GeminiPrompts.cleanSchema(speakers))
            let ids = Set(chunk.map(\.id))
            return try output.paragraphs.map {
                CleanedTranscript.Paragraph(
                    speaker: try Self.known($0.speaker, in: speakers), text: $0.text,
                    sources: Self.sources($0.sources, within: ids))
            }
        } catch is OutputTruncated where chunk.count > 1 {
            let half = chunk.count / 2
            return try await clean(Array(chunk[..<half])) + clean(Array(chunk[half...]))
        } catch is OutputTruncated {
            throw ProviderError(.gemini, .meetingTooLong)
        }
    }

    public func digestPerPerson(_ transcript: LLMTranscript) async throws -> [PersonDigest] {
        guard !transcript.utterances.isEmpty else { return [] }
        try checkLength(transcript.utterances)
        struct Output: Decodable {
            struct Digest: Decodable { let speaker: String; let points: [Point] }
            struct Point: Decodable { let text: String; let sources: [String] }
            let digests: [Digest]
        }
        let speakers = Self.speakers(in: transcript.utterances)
        let output = try await whole(
            Output.self, task: GeminiPrompts.digestPerPerson,
            input: "逐字稿：\n" + GeminiPrompts.render(transcript.utterances),
            schema: GeminiPrompts.digestSchema(speakers))
        let ids = Set(transcript.utterances.map(\.id))
        let digests = try output.digests.map { digest in
            PersonDigest(
                speaker: try Self.known(digest.speaker, in: speakers),
                points: digest.points.map { SourcedText(text: $0.text, sources: Self.sources($0.sources, within: ids)) })
        }
        return digests.sorted { speakers.firstIndex(of: $0.speaker)! < speakers.firstIndex(of: $1.speaker)! }
    }

    public func summarize(_ request: SummaryRequest) async throws -> Summary {
        let utterances = request.transcript.utterances
        guard !utterances.isEmpty else { return Summary(decisions: [], discussionPoints: [], actionItems: []) }
        try checkLength(utterances + request.prioritized)
        struct Output: Decodable {
            struct Point: Decodable { let text: String; let sources: [String] }
            struct Action: Decodable { let text: String; let owner: String?; let sources: [String] }
            let decisions: [Point]
            let discussionPoints: [Point]
            let actionItems: [Action]
        }
        let speakers = Self.speakers(in: utterances)
        let output = try await whole(
            Output.self, task: GeminiPrompts.summarize, input: GeminiPrompts.summaryRequest(request),
            schema: GeminiPrompts.summarySchema(speakers))
        let ids = Set(utterances.map(\.id))
        let sourced = { (points: [Output.Point]) in
            points.map { SourcedText(text: $0.text, sources: Self.sources($0.sources, within: ids)) }
        }
        return Summary(
            decisions: sourced(output.decisions),
            discussionPoints: sourced(output.discussionPoints),
            actionItems: output.actionItems.map { item in
                // An owner outside this meeting is dropped rather than failing the whole summary.
                let owner = item.owner.map(SpeakerID.init).flatMap { speakers.contains($0) ? $0 : nil }
                return .init(text: item.text, owner: owner, sources: Self.sources(item.sources, within: ids))
            })
    }

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

    // MARK: Long meetings

    static func chunks(_ utterances: [LLMUtterance], maxCharacters: Int) -> [[LLMUtterance]] {
        var chunks: [[LLMUtterance]] = []
        var current: [LLMUtterance] = []
        var size = 0
        for utterance in utterances {
            if !current.isEmpty && size + utterance.text.count > maxCharacters {
                chunks.append(current)
                current = []
                size = 0
            }
            current.append(utterance)
            size += utterance.text.count
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func checkLength(_ utterances: [LLMUtterance]) throws {
        if utterances.reduce(0, { $0 + $1.text.count }) > limits.maxInputCharacters {
            throw ProviderError(.gemini, .meetingTooLong)
        }
    }

    /// A whole-transcript task has nothing smaller to retry with when its output hits the cap.
    private func whole<T: Decodable>(_ type: T.Type, task: String, input: String, schema: JSON) async throws -> T {
        do {
            return try await generate(type, task: task, input: input, schema: schema)
        } catch is OutputTruncated {
            throw ProviderError(.gemini, .meetingTooLong)
        }
    }

    // MARK: Validation of model output

    private static func speakers(in utterances: [LLMUtterance]) -> [SpeakerID] {
        var order: [SpeakerID] = []
        for u in utterances where !order.contains(u.speaker) { order.append(u.speaker) }
        return order
    }

    private static func known(_ raw: String, in speakers: [SpeakerID]) throws -> SpeakerID {
        let id = SpeakerID(raw.trimmingCharacters(in: CharacterSet(charactersIn: "{} ")).replacingOccurrences(of: "speaker:", with: ""))
        guard speakers.contains(id) else { throw ProviderError(.gemini, .malformedResponse) }
        return id
    }

    /// Ids the model invented are dropped; the rest keep transcript order without duplicates.
    private static func sources(_ raw: [String], within ids: Set<UtteranceID>) -> [UtteranceID] {
        var seen = Set<UtteranceID>()
        return raw.map(UtteranceID.init).filter { ids.contains($0) && seen.insert($0).inserted }
    }

    // MARK: Transport

    struct OutputTruncated: Error {}

    private func generate<T: Decodable>(_ type: T.Type, task: String, input: String, schema: JSON) async throws -> T {
        let body = JSON.dict([
            ("systemInstruction", .dict([("parts", .list([.dict([("text", .text(GeminiPrompts.common + "\n\n" + task))])]))])),
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
        let text = try Self.candidateText(response.body)
        guard let output = try? JSONDecoder().decode(T.self, from: Data(text.utf8)) else {
            throw ProviderError(.gemini, .malformedResponse)
        }
        return output
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
