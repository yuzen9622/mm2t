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

    static func decode(_ data: String, format: Format) throws -> Chunk {
        if data == "[DONE]" { return .done }
        let service: Service = format == .gemini ? .gemini : .openAICompatible
        guard let object = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
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

    static func stream(_ request: URLRequest, session: URLSession, format: Format) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    defer { bytes.task.cancel() }
                    try await withTaskCancellationHandler {
                        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                        let service: Service = format == .gemini ? .gemini : .openAICompatible
                        guard http.statusCode == 200 else {
                            throw ProviderError(service, HTTPResponse(status: http.statusCode, body: Data()).commonFailure)
                        }
                        var parser = SSEParser()
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            for event in parser.append(Data([byte])) {
                                switch try decode(event, format: format) {
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
        return TextStreaming.stream(request, session: session, format: .gemini)
    }
}

extension OpenAICompatibleLLM {
    public func streamText(system: String, input: String) -> AsyncThrowingStream<String, Error> {
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey.revealed)", forHTTPHeaderField: "Authorization") }
        let messages = JSON.list([
            .dict([("role", .text("system")), ("content", .text(system))]),
            .dict([("role", .text("user")), ("content", .text(input))]),
        ])
        request.httpBody = Data("{\"model\":\(JSON.text(model).serialized()),\"messages\":\(messages.serialized()),\"stream\":true,\"max_tokens\":4096}".utf8)
        return TextStreaming.stream(request, session: session, format: .openAI)
    }
}
