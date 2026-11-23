import Foundation
import MM2TCore

/// The user's own faster-whisper server (`server/` in this repo), over LAN or Tailscale.
/// It never labels speakers, so `labelSpeakers` is ignored.
public struct SelfHostedTranscription: TranscriptionProvider {
    private let service: Service
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
        probeTimeout: TimeInterval = 5, timeout: TimeInterval = 3600, hostedPlan: Bool = false
    ) {
        self.service = hostedPlan ? .mm2tPlan : .selfHosted
        self.baseURL = baseURL
        self.token = token.flatMap { $0.isEmpty ? nil : $0 }
        self.languageCode = languageCode
        self.session = session
        self.probeTimeout = probeTimeout
        self.timeout = timeout
    }

    public func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) async throws -> TranscribedWords {
        do {
            if service != .mm2tPlan { try await checkHealth() }
            let upload = try AudioFile.upload(audio, for: service)
            return .unlabeled(try await post(upload.data, filename: upload.filename, mimeType: upload.mimeType,
                                             hints: hints, languageCode: languageCode))
        } catch let error as ProviderError {
            throw transcriptionError(error)
        }
    }

    private func transcriptionError(_ error: ProviderError) -> TranscriptionError {
        if service == .selfHosted, error.kind == .unreachable, let host = baseURL.host() {
            return .unreachable(String(localized: "Couldn't reach your transcription server (\(host)).", bundle: .main))
        }
        return error.asTranscriptionError
    }

    private func post(_ audio: Data, filename: String, mimeType: String, hints: [String], languageCode: String?) async throws -> [TimedWord] {
        var form = MultipartForm()
        if let languageCode { form.add("language", languageCode) }
        let vocabulary = hints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !vocabulary.isEmpty {
            let json = try JSONEncoder().encode(vocabulary)
            form.add("vocabulary", String(decoding: json, as: UTF8.self))
        }
        form.addFile("file", filename: filename, mimeType: mimeType, data: audio)

        var request = authorized(URLRequest(url: url("v1/transcriptions"), timeoutInterval: timeout))
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finished()
        let response = try await session.send(request, for: service)
        guard response.status == 200 else {
            let failure = service == .mm2tPlan ? response.commonFailure : Self.failure(response)
            throw ProviderError(service, failure)
        }
        return try Self.parse(response.body, service: service)
    }

    /// `/v1/*` checks the token before routing, so a GET on the POST-only transcription route
    /// answers 401 for a bad token and 405 for a good one without uploading anything.
    public func validateKey() async -> KeyCheck {
        do {
            try await checkHealth()
            var request = authorized(URLRequest(url: url("v1/transcriptions"), timeoutInterval: probeTimeout))
            request.httpMethod = "GET"
            let response = try await session.send(request, for: service)
            if response.status == 401 && service != .mm2tPlan {
                return .rejected(token == nil
                    ? String(localized: "The server requires a token. Enter the server's MM2T_SERVER_TOKEN in Settings.", bundle: .main)
                    : ProviderError(service, .invalidCredential).description)
            }
            if (200..<300).contains(response.status) || response.status == 405 { return .valid }
            return .from(ProviderError(service, service == .mm2tPlan ? response.commonFailure : Self.failure(response)))
        } catch let error as ProviderError {
            if error.kind == .unreachable { return .inconclusive(transcriptionError(error).description) }
            return .from(error)
        } catch {
            return .inconclusive(ProviderError(service, .unreachable).description)
        }
    }

    private func checkHealth() async throws {
        let response = try await session.send(URLRequest(url: url("healthz"), timeoutInterval: probeTimeout), for: service)
        guard response.status == 200 else {
            throw ProviderError(service, response.status >= 500 ? .unavailable : .unreachable)
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
    static func parse(_ body: Data, service: Service = .selfHosted) throws -> [TimedWord] {
        guard let response = try? JSONDecoder().decode(Response.self, from: body) else {
            throw ProviderError(service, .malformedResponse)
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

/// Live captions: each clip goes up as a small WAV to the same endpoint the recordings use.
extension SelfHostedTranscription: ClipTranscriber {
    public func prepare() async throws {
        do {
            try await checkHealth()
        } catch let error as ProviderError {
            throw transcriptionError(error)
        }
    }

    public func transcribe(clip samples: [Float], request: StreamingTranscriptionRequest) async throws -> String {
        do {
            let words = try await post(wav(samples, sampleRate: request.sampleRate), filename: "clip.wav", mimeType: "audio/wav",
                                       hints: request.hints, languageCode: request.languageCode)
            return Alignment.joined(words)
        } catch let error as ProviderError {
            throw transcriptionError(error)
        }
    }
}
