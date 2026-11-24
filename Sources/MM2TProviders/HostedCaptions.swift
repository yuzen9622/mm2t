import Foundation
import MM2TCore

/// One instance per recording. The lease outlives its single-use Soniox connections.
public actor HostedCaptions: StreamingTranscriptionProvider {
    private struct Lease: Decodable, Sendable {
        struct Features: Decodable, Sendable { let liveCaptions: Bool }
        let id: String
        let expiresAt: Date
        let features: Features
    }

    private struct Ticket: Decodable {
        let apiKey: String
        let expiresAt: Date
        let websocketUrl: URL
        let model: String
        let maxSessionSeconds: Int
    }

    private struct Configuration: Encodable {
        let api_key: String
        let model: String
        let audio_format = "pcm_s16le"
        let sample_rate: Int
        let num_channels = 1
        let language_hints: [String]
    }

    private struct API: Sendable {
        let url: URL
        let authorization: HostedAuthorization
        let http: URLSession
        let leases: HostedLeases

        func post(_ path: String...) async throws -> HTTPResponse {
            let endpoint = path.reduce(url) { $0.appending(component: $1) }
            let response: HTTPResponse
            do {
                response = try await authorization.send(http) { token in
                    var request = URLRequest(url: endpoint, timeoutInterval: 10)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(token.revealed)", forHTTPHeaderField: "Authorization")
                    return request
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ProviderError where error.kind == .invalidCredential {
                throw StreamingTranscriptionAvailability.ineligible
            } catch {
                throw TranscriptionError.unreachable("Hosted captions could not connect")
            }
            return response
        }

        func body(_ response: HTTPResponse) throws -> Data {
            switch response.status {
            case 200..<300: return response.body
            case 401, 402, 403, 404, 409: throw StreamingTranscriptionAvailability.ineligible
            default: throw TranscriptionError.unreachable("Hosted captions are unavailable")
            }
        }

        func begin() async throws -> Lease {
            let first = try await post()
            guard first.status == 409, first.hostedCode == "session_active" else {
                return try HostedCaptions.decode(Lease.self, from: body(first))
            }
            let abandoned = await leases.unassignedLeases()
            guard !abandoned.isEmpty else { throw StreamingTranscriptionAvailability.ineligible }
            for id in abandoned { await finish(id) }
            return try HostedCaptions.decode(Lease.self, from: body(await post()))
        }

        func finish(_ id: String) async {
            if let response = try? await post(id, "finish"),
               (200..<300).contains(response.status) || response.status == 404
                   || (response.status == 409 && response.hostedCode == "session_closed") {
                await leases.finished(id)
            } else {
                await leases.rememberForCleanup(id)
            }
        }
    }

    private static let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    private let api: API
    private let socket: @Sendable (URL) -> any CaptionWebSocket
    private let traditionalChinese: Bool
    private let leases: HostedLeases
    private var leaseTask: Task<Lease, Error>?
    private var stopped = false

    public init(url: URL, authorization: HostedAuthorization, traditionalChinese: Bool, leases: HostedLeases) {
        self.init(url: url, authorization: authorization, traditionalChinese: traditionalChinese,
                  leases: leases, http: .shared, socket: { url in
                      let task = URLSession.shared.webSocketTask(with: URLRequest(url: url, timeoutInterval: 10))
                      task.resume()
                      return task
                  })
    }

    init(url: URL, authorization: HostedAuthorization, traditionalChinese: Bool, leases: HostedLeases, http: URLSession,
         socket: @escaping @Sendable (URL) -> any CaptionWebSocket) {
        api = API(url: url, authorization: authorization, http: http, leases: leases)
        self.traditionalChinese = traditionalChinese
        self.leases = leases
        self.socket = socket
    }

    private func lease() async throws -> Lease {
        guard !stopped else { throw CancellationError() }
        if let leaseTask { return try await leaseTask.value }
        let task = Task { [api] in
            let lease = try await api.begin()
            if !lease.features.liveCaptions { await api.finish(lease.id) }
            return lease
        }
        leaseTask = task
        do {
            return try await task.value
        } catch {
            leaseTask = nil
            throw error
        }
    }

    public func open(_ request: StreamingTranscriptionRequest) async throws -> any StreamingTranscriptionSession {
        let lease = try await lease()
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        guard lease.features.liveCaptions, lease.expiresAt > Date() else {
            throw StreamingTranscriptionAvailability.ineligible
        }
        let ticket = try Self.decode(Ticket.self, from: api.body(await api.post(lease.id, "captions")))
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        guard ticket.websocketUrl == Self.endpoint else {
            throw TranscriptionError.unreachable("Invalid hosted captions endpoint")
        }
        // The ticket's expiry is the deadline to authenticate, not the lifetime of the open socket.
        guard ticket.expiresAt > Date(), ticket.maxSessionSeconds > 0 else { throw SonioxConnection.Interrupted() }
        let configuration = Configuration(api_key: ticket.apiKey, model: ticket.model,
                                          sample_rate: request.sampleRate, language_hints: request.languageCode.map { [$0] } ?? [])
        let frame = String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)
        let transport = socket(ticket.websocketUrl)
        do {
            try await withTaskCancellationHandler {
                try await transport.send(.string(frame))
                try Task.checkCancellation()
            } onCancel: {
                transport.closeSocket()
            }
        } catch {
            transport.closeSocket()
            try Task.checkCancellation()
            throw SonioxConnection.Interrupted()
        }
        let duration = min(Double(ticket.maxSessionSeconds), lease.expiresAt.timeIntervalSinceNow)
        let renewAfter = max(duration / 2, duration - 5)
        let connection = SonioxConnection(socket: transport, traditionalChinese: traditionalChinese || request.languageCode == "zh")
        await connection.start(renewAfter: .seconds(max(0, renewAfter)))
        return connection
    }

    public func stop(retainingLeaseFor meeting: MeetingID?) async {
        guard !stopped else { return }
        stopped = true
        defer { leaseTask = nil }
        guard let leaseTask, let lease = try? await leaseTask.value, lease.features.liveCaptions else { return }
        if let meeting, lease.expiresAt > Date(), await leases.adopt(lease.id, for: meeting.description) { return }
        await api.finish(lease.id)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: value) { return date }
            iso.formatOptions = [.withInternetDateTime]
            guard let date = iso.date(from: value) else {
                throw TranscriptionError.unreachable("Invalid hosted captions date")
            }
            return date
        }
        do { return try decoder.decode(type, from: data) }
        catch { throw TranscriptionError.unreachable("Invalid hosted captions response") }
    }
}

protocol CaptionWebSocket: Sendable {
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func closeSocket()
}

extension URLSessionWebSocketTask: CaptionWebSocket {
    func closeSocket() { cancel(with: .normalClosure, reason: nil) }
}

private actor SonioxConnection: StreamingTranscriptionSession {
    struct Interrupted: Error {}

    private struct Response: Decodable {
        struct Token: Decodable {
            let text: String
            let is_final: Bool
        }
        let tokens: [Token]?
        let finished: Bool?
        let error_code: Int?
        let error_message: String?
    }

    nonisolated let events: AsyncThrowingStream<StreamingTranscriptEvent, Error>
    private let output: AsyncThrowingStream<StreamingTranscriptEvent, Error>.Continuation
    private let socket: any CaptionWebSocket
    private let traditionalChinese: Bool
    private var reader: Task<Void, Never>?
    private var renewal: Task<Void, Never>?
    private var closing = false
    private var closed = false

    init(socket: any CaptionWebSocket, traditionalChinese: Bool) {
        (events, output) = AsyncThrowingStream.makeStream()
        self.socket = socket
        self.traditionalChinese = traditionalChinese
    }

    func start(renewAfter: Duration) {
        reader = Task { await read() }
        renewal = Task {
            do { try await Task.sleep(for: renewAfter) } catch { return }
            await close()
        }
    }

    func send(_ samples: [Float]) async throws {
        guard !samples.isEmpty, !closing, !closed else { return }
        do { try await socket.send(.data(pcm16(samples))) }
        catch {
            finish(throwing: Interrupted())
            throw Interrupted()
        }
    }

    func close() async {
        guard !closing, !closed else { return }
        closing = true
        let timeout = Task { [socket] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            socket.closeSocket()
        }
        defer { timeout.cancel() }
        do {
            try await socket.send(.string(""))
            await reader?.value
        } catch { finish(throwing: Interrupted()) }
    }

    private func read() async {
        do {
            while !closed {
                let data: Data
                switch try await socket.receive() {
                case .string(let value): data = Data(value.utf8)
                case .data(let value): data = value
                @unknown default: throw Interrupted()
                }
                guard !closed else { return }
                let response = try JSONDecoder().decode(Response.self, from: data)
                if let tokens = response.tokens {
                    var final = ""
                    var partial = ""
                    for token in tokens where token.text != "<end>" && token.text != "<fin>" {
                        if token.is_final { final += token.text } else { partial += token.text }
                    }
                    if !final.isEmpty { output.yield(.final(convert(final))) }
                    output.yield(.partial(convert(partial)))
                }
                if response.error_code != nil || response.error_message != nil { throw Interrupted() }
                if response.finished == true {
                    finish()
                    return
                }
            }
        } catch { finish(throwing: Interrupted()) }
    }

    private func convert(_ text: String) -> String {
        traditionalChinese ? TraditionalChinese.convert(text) : text
    }

    private func finish(throwing error: Interrupted? = nil) {
        guard !closed else { return }
        closed = true
        output.finish(throwing: error)
        renewal?.cancel()
        reader?.cancel()
        socket.closeSocket()
    }
}
