import Foundation
import MM2TCore

struct SSEParser {
    private var bytes = Data()
    private var fields: [String] = []

    mutating func append(_ chunk: Data) -> [String] {
        bytes.append(chunk)
        var events: [String] = []
        while let newline = bytes.firstIndex(of: 10) {
            var line = String(decoding: bytes[..<newline], as: UTF8.self)
            bytes.removeSubrange(...newline)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty {
                if !fields.isEmpty { events.append(fields.joined(separator: "\n")); fields = [] }
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                fields.append(value)
            }
        }
        return events
    }
}

enum TextStreaming {
    enum Format: Sendable { case gemini, openAI }
    enum Chunk { case text(String), done }

    static func decode(_ data: String, format: Format, service: Service) throws -> Chunk {
        if data == "[DONE]" { return .done }
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              object["error"] == nil else { throw ProviderError(service, .malformedResponse) }
        switch format {
        case .gemini:
            if (object["promptFeedback"] as? [String: Any])?["blockReason"] != nil {
                throw ProviderError(service, .blocked)
            }
            guard let candidate = (object["candidates"] as? [[String: Any]])?.first else {
                if object["usageMetadata"] != nil { return .text("") }
                throw ProviderError(service, .malformedResponse)
            }
            if let reason = candidate["finishReason"] as? String, reason != "STOP" {
                if reason == "MAX_TOKENS" { throw OutputTruncated() }
                throw ProviderError(service, .blocked)
            }
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            return .text(parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined())
        case .openAI:
            guard let choices = object["choices"] as? [[String: Any]] else {
                throw ProviderError(service, .malformedResponse)
            }
            guard let choice = choices.first else { return .text("") }
            if let reason = choice["finish_reason"] as? String, reason != "stop" {
                if reason == "length" { throw OutputTruncated() }
                throw ProviderError(service, .blocked)
            }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            if let refusal = delta["refusal"] as? String, !refusal.isEmpty { throw ProviderError(service, .blocked) }
            return .text(delta["content"] as? String ?? "")
        }
    }

    /// Starts the request. Connection failures map like `URLSession.send`; any HTTP status is returned.
    static func connect(_ request: URLRequest, session: URLSession, service: Service) async throws -> (URLSession.AsyncBytes, Int) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ProviderError(service, .malformedResponse) }
            return (bytes, http.statusCode)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw ProviderError(service, URLSession.isConnectionFailure(error) ? .unreachable : .serviceError)
        }
    }

    /// An error response's body, bounded, so its message can be classified.
    static func errorBody(_ bytes: URLSession.AsyncBytes) async -> Data {
        var body = Data()
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 65_536 { break }
            }
        } catch {}
        bytes.task.cancel()
        return body
    }

    /// `open` returns the body of a 200 response, or throws the provider's failure.
    static func stream(format: Format, service: Service, open: @escaping @Sendable () async throws -> URLSession.AsyncBytes) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await open()
                    defer { bytes.task.cancel() }
                    try await withTaskCancellationHandler {
                        var parser = SSEParser()
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            for event in parser.append(Data([byte])) {
                                switch try decode(event, format: format, service: service) {
                                case .done: continuation.finish(); return
                                case .text(let text): if !text.isEmpty { continuation.yield(text) }
                                }
                            }
                        }
                        continuation.finish()
                    } onCancel: { bytes.task.cancel() }
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension GeminiLLM {
    public func streamText(system: String, input: String) -> AsyncThrowingStream<String, Error> {
        var url = URLComponents(url: Self.base.appending(path: "\(model):streamGenerateContent"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        var request = URLRequest(url: url.url!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(apiKey.revealed, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(JSON.dict([
            ("systemInstruction", .dict([("parts", .list([.dict([("text", .text(system))])]))])),
            ("contents", .list([.dict([("role", .text("user")), ("parts", .list([.dict([("text", .text(input))])]))])])),
        ]).serialized().utf8)
        return TextStreaming.stream(format: .gemini, service: .gemini) { [session, request] in
            let (bytes, status) = try await TextStreaming.connect(request, session: session, service: .gemini)
            guard status == 200 else {
                throw ProviderError(.gemini, GeminiLLM.failure(HTTPResponse(status: status, body: await TextStreaming.errorBody(bytes))))
            }
            return bytes
        }
    }
}

extension OpenAICompatibleLLM {
    public func streamText(system: String, input: String) -> AsyncThrowingStream<String, Error> {
        TextStreaming.stream(format: .openAI, service: service) { [self] in try await openStream(system: system, input: input) }
    }
}
