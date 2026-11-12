import Foundation
import MM2TCore

/// The user's own faster-whisper server (`server/` in this repo), over LAN or Tailscale.
/// It never labels speakers, so `labelSpeakers` is ignored.
public struct SelfHostedTranscription: TranscriptionProvider {
    let baseURL: URL
    let token: Secret?
    let languageCode: String?
    let session: URLSession
    let probeTimeout: TimeInterval
    let timeout: TimeInterval

    /// `probeTimeout` bounds the health check that runs before each upload: an offline Tailscale
    /// peer drops packets instead of refusing, and the upload's long timeout would otherwise
    /// stall the fallback chain for its full length.
    public init(
        baseURL: URL, token: Secret?, languageCode: String? = nil, session: URLSession = .shared,
        probeTimeout: TimeInterval = 5, timeout: TimeInterval = 3600
    ) {
        self.baseURL = baseURL
        self.token = token.flatMap { $0.isEmpty ? nil : $0 }
        self.languageCode = languageCode
        self.session = session
        self.probeTimeout = probeTimeout
        self.timeout = timeout
    }

    public func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) async throws -> TranscribedWords {
        do {
            try await checkHealth()
            let audioData = try AudioFile.read(audio, for: .selfHosted)
            var form = MultipartForm()
            if let languageCode { form.add("language", languageCode) }
            let vocabulary = hints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !vocabulary.isEmpty {
                let json = try JSONEncoder().encode(vocabulary)
                form.add("vocabulary", String(decoding: json, as: UTF8.self))
            }
            form.addFile("file", filename: audio.lastPathComponent, mimeType: AudioFile.mimeType(audio), data: audioData)

            var request = authorized(URLRequest(url: url("v1/transcriptions"), timeoutInterval: timeout))
            request.httpMethod = "POST"
            request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = form.finished()
            let response = try await session.send(request, for: .selfHosted)
            guard response.status == 200 else { throw ProviderError(.selfHosted, Self.failure(response)) }
            return .unlabeled(try Self.parse(response.body))
        } catch let error as ProviderError {
            throw error.asTranscriptionError
        }
    }

    /// `/v1/*` checks the token before routing, so a GET on the POST-only transcription route
    /// answers 401 for a bad token and 405 for a good one without uploading anything.
    public func validateKey() async -> KeyCheck {
        do {
            try await checkHealth()
            var request = authorized(URLRequest(url: url("v1/transcriptions"), timeoutInterval: probeTimeout))
            request.httpMethod = "GET"
            let response = try await session.send(request, for: .selfHosted)
            if response.status == 401 {
                return .rejected(token == nil
                    ? String(localized: "The server requires a token. Enter the server's MM2T_SERVER_TOKEN in Settings.", bundle: .main)
                    : ProviderError(.selfHosted, .invalidCredential).description)
            }
            return .valid
        } catch let error as ProviderError {
            return .from(error)
        } catch {
            return .inconclusive(ProviderError(.selfHosted, .unreachable).description)
        }
    }

    private func checkHealth() async throws {
        let response = try await session.send(URLRequest(url: url("healthz"), timeoutInterval: probeTimeout), for: .selfHosted)
        guard response.status == 200 else {
            throw ProviderError(.selfHosted, response.status >= 500 ? .unavailable : .unreachable)
        }
    }

    private func url(_ path: String) -> URL {
        baseURL.appending(path: path)
    }

    private func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        if let token { request.setValue("Bearer \(token.revealed)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let code: String }
        let error: Detail
    }

    static func failure(_ response: HTTPResponse) -> ProviderError.Kind {
        let code = (try? JSONDecoder().decode(ErrorBody.self, from: response.body))?.error.code
        switch code {
        case "invalid_audio": return .audioUnreadable
        case "payload_too_large": return .audioTooLarge
        case "unauthorized": return .invalidCredential
        case "engine_error": return .serviceError
        default: return response.commonFailure
        }
    }

    private struct Response: Decodable {
        struct Segment: Decodable {
            let start: Double
            let end: Double
            let text: String
            let words: [Word]
        }
        struct Word: Decodable {
            let word: String
            let start: Double
            let end: Double
        }
        let segments: [Segment]
    }

    /// Whisper words carry a leading space ("␠hello"); the core joins tokens itself.
    static func parse(_ body: Data) throws -> [TimedWord] {
        guard let response = try? JSONDecoder().decode(Response.self, from: body) else {
            throw ProviderError(.selfHosted, .malformedResponse)
        }
        var words: [TimedWord] = []
        var previousEnd = 0.0
        for segment in response.segments {
            let tokens = segment.words.isEmpty
                ? [Response.Word(word: segment.text, start: segment.start, end: segment.end)]
                : segment.words
            for token in tokens {
                let text = token.word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let range = wordRange(token.start, token.end, after: previousEnd)
                previousEnd = range.end
                words.append(TimedWord(text, range.start, range.end))
            }
        }
        return words.sorted { $0.range.start < $1.range.start }
    }
}
