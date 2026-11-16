import Foundation
import MM2TCore

// ElevenLabs Scribe v3 Live, read 2026-11-16:
//   https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime
//   https://elevenlabs.io/docs/overview/models
//   https://elevenlabs.io/docs/changelog (Scribe v3, 2026-11-09)
//   https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/event-reference
//   https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/transcripts-and-commit-strategies
//   https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/keyterm-prompting
//   https://elevenlabs.io/pricing/api
// - WSS wss://api.elevenlabs.io/v1/speech-to-text/realtime, key in the `xi-api-key` header.
// - scribe_v3_live succeeds scribe_v2_realtime on the same socket, with the same query parameters
//   and messages; v2 remains available and is still the endpoint's default model_id.
//   Query: model_id, audio_format (pcm_16000 ...), commit_strategy (manual default | vad | turn_prediction),
//   language_code, keyterms (repeated; realtime: at most 50, 20 characters each, billed extra),
//   keepalive_interval_ms (500...10000).
// - Client sends {"message_type":"input_audio_chunk","audio_base_64","commit","sample_rate"};
//   `previous_text` (best under 50 characters) only with the first chunk of a session.
// - Server sends session_started, then partial_transcript {text} (later partials replace earlier
//   ones; also the keepalive, with empty text when nothing is uncommitted) and committed_transcript
//   {text} (final for the segment). Errors arrive as a message whose message_type is the error type,
//   with `error` text, before the socket closes.
// - The server closes a session after 15 s without client messages. All streamed audio is billed,
//   silence included, so a paused recording closes the socket rather than idling it.
// - List price: $0.22 per hour of audio for Scribe v3 Live (same as v2 Realtime); keyterm prompting
//   is a $0.08 per hour add-on.

/// Live captions from ElevenLabs Scribe v3 Live over a WebSocket. Display only: nothing it
/// returns is stored.
public struct ElevenLabsRealtime: StreamingTranscriptionProvider {
    public static let endpoint = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
    public static let model = "scribe_v3_live"
    /// The realtime keyterm limits, lower than batch.
    static let maxKeyterms = 50
    static let maxKeytermLength = 20
    /// Keeps a quiet room's socket visibly alive; it costs nothing beyond the audio already sent.
    static let keepaliveMilliseconds = 5000
    static let previousTextLimit = 50

    let apiKey: Secret
    let session: URLSession

    public init(apiKey: Secret, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func open(_ request: StreamingTranscriptionRequest) async throws -> any StreamingTranscriptionSession {
        var urlRequest = URLRequest(url: Self.url(for: request), timeoutInterval: 30)
        urlRequest.setValue(apiKey.revealed, forHTTPHeaderField: "xi-api-key")
        let task = session.webSocketTask(with: urlRequest)
        task.resume()
        do {
            // The first message is session_started, or an error explaining why the session was refused.
            switch Self.decode(try await task.receive()) {
            case .sessionStarted: break
            case .failure(let error): throw error
            default: throw ProviderError(.elevenLabs, .malformedResponse).asTranscriptionError
            }
        } catch {
            task.cancel(with: .normalClosure, reason: nil)
            throw Self.transcriptionError(error, response: task.response)
        }
        return Connection(task: task, sampleRate: request.sampleRate,
                          previousText: request.previousText.map { String($0.suffix(Self.previousTextLimit)) })
    }

    // MARK: Encoding

    static func url(for request: StreamingTranscriptionRequest) -> URL {
        var items = [
            URLQueryItem(name: "model_id", value: model),
            URLQueryItem(name: "audio_format", value: "pcm_\(request.sampleRate)"),
            URLQueryItem(name: "commit_strategy", value: "vad"),
            URLQueryItem(name: "keepalive_interval_ms", value: String(keepaliveMilliseconds)),
        ]
        if let code = request.languageCode { items.append(URLQueryItem(name: "language_code", value: code)) }
        for term in ElevenLabsScribe.keyterms(from: request.hints, limit: maxKeyterms, maxLength: maxKeytermLength) {
            items.append(URLQueryItem(name: "keyterms", value: term))
        }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        return components.url!
    }

    private struct AudioChunk: Encodable {
        let message_type = "input_audio_chunk"
        let audio_base_64: String
        let commit = false
        let sample_rate: Int
        let previous_text: String?
    }

    /// Samples become 16-bit little-endian PCM exactly as the recorder writes them to its WAV files.
    static func audioMessage(_ samples: [Float], sampleRate: Int, previousText: String? = nil) -> String {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = sample.isNaN ? 0 : max(-1, min(1, sample))
            withUnsafeBytes(of: Int16(clamped * Float(Int16.max)).littleEndian) { pcm.append(contentsOf: $0) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let chunk = AudioChunk(audio_base_64: pcm.base64EncodedString(), sample_rate: sampleRate, previous_text: previousText)
        return String(decoding: try! encoder.encode(chunk), as: UTF8.self)
    }

    // MARK: Decoding

    enum Message: Equatable {
        case sessionStarted
        case transcript(StreamingTranscriptEvent)
        case failure(TranscriptionError)
        /// Timestamps, warnings and anything newer than this client.
        case ignored
    }

    private struct Envelope: Decodable {
        let message_type: String
        let text: String?
        let error: String?
    }

    static func decode(_ message: URLSessionWebSocketTask.Message) -> Message {
        switch message {
        case .string(let text): decode(Data(text.utf8))
        case .data(let data): decode(data)
        @unknown default: .ignored
        }
    }

    static func decode(_ data: Data) -> Message {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return .failure(ProviderError(.elevenLabs, .malformedResponse).asTranscriptionError)
        }
        switch envelope.message_type {
        case "session_started": return .sessionStarted
        case "partial_transcript": return .transcript(.partial(envelope.text ?? ""))
        case "committed_transcript": return .transcript(.final(envelope.text ?? ""))
        default:
            guard let kind = failure(envelope.message_type) else { return .ignored }
            return .failure(ProviderError(.elevenLabs, kind).asTranscriptionError)
        }
    }

    /// The documented error types. Those that a new session can get past become `.unreachable` or
    /// `.unavailable`, which the caller reconnects after; the rest need the user.
    static func failure(_ type: String) -> ProviderError.Kind? {
        switch type {
        case "auth_error": .invalidCredential
        case "quota_exceeded": .outOfCredit
        case "unaccepted_terms": .permissionDenied
        case "invalid_request", "input_error", "chunk_size_exceeded": .rejectedInput
        case "rate_limited", "queue_overflow", "commit_throttled", "resource_exhausted": .unavailable
        case "error", "transcriber_error", "session_time_limit_exceeded", "insufficient_audio_activity": .unreachable
        default: nil
        }
    }

    /// A refused upgrade carries its HTTP status (401 for a bad key); a dropped connection is worth retrying.
    static func transcriptionError(_ error: Error, response: URLResponse?) -> Error {
        if error is TranscriptionError || error is CancellationError { return error }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            return ProviderError(.elevenLabs, HTTPResponse(status: http.statusCode, body: Data()).commonFailure).asTranscriptionError
        }
        if let error = error as? URLError, error.code == .cancelled { return CancellationError() }
        return ProviderError(.elevenLabs, .unreachable).asTranscriptionError
    }

    // MARK: Connection

    final class Connection: StreamingTranscriptionSession, @unchecked Sendable {
        let events: AsyncThrowingStream<StreamingTranscriptEvent, Error>
        private let task: URLSessionWebSocketTask
        private let sampleRate: Int
        private let lock = NSLock()
        private var previousText: String?
        private let reader: Task<Void, Never>

        init(task: URLSessionWebSocketTask, sampleRate: Int, previousText: String?) {
            self.task = task
            self.sampleRate = sampleRate
            self.previousText = previousText?.isEmpty == false ? previousText : nil
            let (events, continuation) = AsyncThrowingStream<StreamingTranscriptEvent, Error>.makeStream()
            self.events = events
            reader = Task {
                do {
                    while !Task.isCancelled {
                        switch ElevenLabsRealtime.decode(try await task.receive()) {
                        case .transcript(let event): continuation.yield(event)
                        case .failure(let error): throw error
                        case .sessionStarted, .ignored: break
                        }
                    }
                    continuation.finish()
                } catch {
                    let mapped = ElevenLabsRealtime.transcriptionError(error, response: nil)
                    if mapped is CancellationError { continuation.finish() } else { continuation.finish(throwing: mapped) }
                }
            }
            continuation.onTermination = { [reader] _ in reader.cancel() }
        }

        func send(_ samples: [Float]) async throws {
            guard !samples.isEmpty else { return }
            let context = lock.withLock {
                defer { previousText = nil }
                return previousText
            }
            let message = ElevenLabsRealtime.audioMessage(samples, sampleRate: sampleRate, previousText: context)
            do {
                try await task.send(.string(message))
            } catch {
                throw ElevenLabsRealtime.transcriptionError(error, response: nil)
            }
        }

        func close() async {
            reader.cancel()
            task.cancel(with: .normalClosure, reason: nil)
        }
    }
}
