import Foundation
import MM2TCore
import Testing
@testable import MM2TApp
@testable import MM2TProviders

@MainActor
struct HostedCaptionStreamTests {
    @Test func socketFailureReconnectsWithANewKeyAndPreservesDisplayedCaptions() async throws {
        let first = CaptionSocket(), second = CaptionSocket()
        let sockets = Box([first, second])
        let (provider, local) = try makeRoute(socket: { _ in
            var result: CaptionSocket?
            sockets.update { if !$0.isEmpty { result = $0.removeFirst() } }
            return result ?? CaptionSocket()
        })
        let captions = LiveCaptions()
        let stream = CaptionStream(provider: provider, languageCode: nil, hints: [], captions: captions, sleep: { _ in })
        let (audio, feed) = AsyncStream<[Float]>.makeStream()
        await stream.start(audio: audio, sampleRate: 16_000)
        #expect(await eventually { captions.status == .live && first.config.get != nil })
        first.reply(#"{"tokens":[{"text":"第一条","is_final":true}]}"#)
        #expect(await eventually { captions.segments.map(\.text) == ["第一條"] })
        first.drop()
        #expect(await eventually { captions.status == .live && second.config.get != nil })
        second.reply(#"{"tokens":[{"text":"第二条","is_final":true}]}"#)
        #expect(await eventually { captions.segments.map(\.text) == ["第一條", "第二條"] })
        feed.yield(Array(repeating: 0.1, count: 3_200))
        #expect(await eventually { second.received.get.count == 6_400 })
        let firstKey = try #require(first.config.get)
        let secondKey = try #require(second.config.get)
        #expect(firstKey != secondKey)
        #expect(local.requests.get.isEmpty)
        await stream.stop()
        feed.finish()
    }

    @Test func plannedRotationKeepsPartialAndReplaysOnlyTheNewestFifteenSeconds() async throws {
        let first = CaptionSocket(), second = CaptionSocket()
        let sockets = Box([first, second])
        let (route, _) = try makeRoute { _ in
            var next: CaptionSocket?
            sockets.update { if !$0.isEmpty { next = $0.removeFirst() } }
            return next ?? CaptionSocket()
        }
        let provider = GatedRotation(route: route)
        let time = Box(ContinuousClock.now)
        let waits = Box<[Duration]>([])
        let captions = LiveCaptions()
        let stream = CaptionStream(provider: provider, languageCode: nil, hints: [], captions: captions,
                                   now: { time.get }, sleep: { duration in waits.update { $0.append(duration) } })
        let (audio, input) = AsyncStream<[Float]>.makeStream()
        await stream.start(audio: audio, sampleRate: 100)
        #expect(await eventually { captions.status == .live })
        first.reply(#"{"tokens":[{"text":"partial","is_final":false}]}"#)
        #expect(await eventually { captions.partial == "partial" })
        time.update { $0 = $0.advanced(by: .seconds(30)) }
        // Hold the final server acknowledgement while the old socket is already rejecting audio.
        first.holdClose.set(true)
        let session = try #require(provider.first.get)
        let closing = Task { await session.close() }
        #expect(await eventually { first.closing.get })
        await stream.feed(Array(repeating: 0.25, count: 100))
        first.reply(#"{"finished":true}"#)
        await closing.value
        #expect(await eventually { provider.reopening.get })
        #expect(captions.status == .live)
        #expect(captions.partial == "partial")
        #expect(waits.get.isEmpty)
        let gap = (0..<1451).map { Float($0) / 2000 }
        await stream.feed(gap)
        await provider.gate.open(true)
        let retained = Array(repeating: Float(0.25), count: 49) + gap
        #expect(await eventually { second.received.get == pcm16(retained) })
        input.yield(Array(repeating: -0.5, count: 10))
        #expect(await eventually { second.received.get == pcm16(retained + Array(repeating: -0.5, count: 10)) })
        #expect(first.received.get.isEmpty)
        await stream.stop()
        input.finish()
    }

    @Test(arguments: [false, true])
    func earlyNormalCloseAndRateLimitedTicketUseBackoff(rateLimited: Bool) async throws {
        let socket = CaptionSocket()
        let (route, _) = try makeRoute(rateLimited: rateLimited) { _ in socket }
        let hostedOnly = StreamingTranscriptionChain([try #require(route.routes.first)])
        let time = Box(ContinuousClock.now)
        let captions = LiveCaptions()
        let waits = Box<[Duration]>([])
        let gate = Gate<Bool>()
        let stream = CaptionStream(provider: hostedOnly, languageCode: nil, hints: [], captions: captions,
                                   now: { time.get }, sleep: { duration in
                                       waits.update { $0.append(duration) }
                                       _ = await gate.wait()
                                   })
        let (audio, input) = AsyncStream<[Float]>.makeStream()
        await stream.start(audio: audio, sampleRate: 16_000)
        if !rateLimited {
            #expect(await eventually { captions.status == .live })
            time.update { $0 = $0.advanced(by: .seconds(29)) }
            socket.reply(#"{"finished":true}"#)
        }
        #expect(await eventually { waits.get == [.seconds(1)] })
        #expect(captions.status == .reconnecting)
        if rateLimited { #expect(socket.config.get == nil) }
        await stream.stop()
        await gate.open(true)
        input.finish()
    }

    @Test func freePlanFallsThroughSilentlyToLocal() async throws {
        let (provider, local) = try makeRoute(free: true) { _ in
            Issue.record("Free must not attempt a Soniox connection")
            return CaptionSocket()
        }
        let captions = LiveCaptions()
        let stream = CaptionStream(provider: provider, languageCode: nil, hints: [], captions: captions)
        let (audio, feed) = AsyncStream<[Float]>.makeStream()
        await stream.start(audio: audio, sampleRate: 16_000)
        #expect(await eventually { captions.status == .live && local.last != nil })
        local.last?.say(.final("本機字幕"))
        #expect(await eventually { captions.segments.map(\.text) == ["本機字幕"] })
        await stream.stop()
        feed.finish()
    }

    private func makeRoute(free: Bool = false, rateLimited: Bool = false, socket: @escaping @Sendable (URL) -> any CaptionWebSocket) throws
        -> (StreamingTranscriptionChain, FakeStreamingSTT) {
        let plan = rateLimited ? "limited" : (free ? "free" : "paid")
        let api = URL(string: "https://captions.invalid/\(plan)")!
        let world = try World()
        try world.credentials.save(Secret(#"{"apiURL":"\#(api.absoluteString)","tokens":{"accessToken":"fixture","refreshToken":"fixture"}}"#), for: .collabAccount)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CaptionHTTP.self]
        let session = URLSession(configuration: config)
        world.catalog.makeHostedCaptions.set { url, authorization, traditionalChinese in
            HostedCaptions(url: url, authorization: authorization, traditionalChinese: traditionalChinese,
                           leases: HostedLeases(), http: session, socket: socket)
        }
        var settings = AppSettings()
        settings.localCaptionModel = .breeze
        world.catalog.offlineDownloaded[.transcription]!.set(true)
        let setup = PipelineSetup(library: world.library, voiceprints: world.app.voiceprints,
                                  credentials: world.credentials, catalog: world.catalog)
        let provider = try #require(setup.buildCaptions(settings, accountURL: api, interfaceLanguage: "zh-TW"))
        #expect(provider.routes.map(\.source) == [.mm2t, .local])
        return (provider, world.catalog.localStreaming)
    }
}

private final class GatedRotation: StreamingTranscriptionProvider, Sendable {
    let route: StreamingTranscriptionChain
    let first = Box<(any StreamingTranscriptionSession)?>(nil)
    let reopening = Box(false)
    let gate = Gate<Bool>()

    init(route: StreamingTranscriptionChain) { self.route = route }

    func open(_ request: StreamingTranscriptionRequest) async throws -> any StreamingTranscriptionSession {
        if first.get != nil {
            reopening.set(true)
            _ = await gate.wait()
            return try await route.open(request)
        }
        let session = try await route.open(request)
        first.set(session)
        return session
    }
}

private final class CaptionHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "captions.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let body: String
        let status: Int
        switch url.lastPathComponent {
        case "sessions":
            status = 200
            body = #"{"id":"lease","expiresAt":"2099-01-01T00:00:00Z","maxSeconds":7200,"features":{"liveCaptions":\#(!url.path.hasPrefix("/free/"))}}"#
        case "captions":
            status = url.path.hasPrefix("/limited/") ? 429 : 200
            body = #"{"apiKey":"\#(UUID())","expiresAt":"2099-01-01T00:00:00Z","websocketUrl":"wss://stt-rt.soniox.com/transcribe-websocket","model":"stt-rt-v6","maxSessionSeconds":7200}"#
        case "finish":
            status = 204
            body = ""
        default:
            status = 404
            body = ""
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class CaptionSocket: CaptionWebSocket, Sendable {
    private let input = AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>.makeStream()
    let config = Box<String?>(nil)
    let holdClose = Box(false)
    let closing = Box(false)
    let received = Box(Data())

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        switch message {
        case .string(""):
            closing.set(true)
            if !holdClose.get { reply(#"{"finished":true}"#) }
        case .string(let json):
            let payload = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            config.set(payload?["api_key"] as? String)
        case .data(let data): received.update { $0.append(data) }
        @unknown default: break
        }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        var iterator = input.stream.makeAsyncIterator()
        guard let message = try await iterator.next() else { throw URLError(.networkConnectionLost) }
        return message
    }
    func reply(_ json: String) { input.continuation.yield(.string(json)) }
    func drop() { input.continuation.finish(throwing: URLError(.networkConnectionLost)) }
    func closeSocket() { input.continuation.finish() }
}
