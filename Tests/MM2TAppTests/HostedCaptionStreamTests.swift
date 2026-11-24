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
        #expect(await eventually { second.bytes.get == 6_400 })
        let firstKey = try #require(first.config.get)
        let secondKey = try #require(second.config.get)
        #expect(firstKey != secondKey)
        #expect(local.requests.get.isEmpty)
        await stream.stop()
        feed.finish()
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

    private func makeRoute(free: Bool = false, socket: @escaping @Sendable (URL) -> any CaptionWebSocket) throws
        -> (StreamingTranscriptionChain, FakeStreamingSTT) {
        let api = URL(string: "https://captions.invalid/\(free ? "free" : "paid")")!
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
            status = 200
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
    let bytes = Box(0)

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        switch message {
        case .string(""): reply(#"{"finished":true}"#)
        case .string(let json):
            let payload = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            config.set(payload?["api_key"] as? String)
        case .data(let data): bytes.update { $0 += data.count }
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
