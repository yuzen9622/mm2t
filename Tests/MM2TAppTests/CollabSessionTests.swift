import Foundation
import MM2TCore
import MM2TProviders
import Testing
@testable import MM2TApp

@MainActor struct CollabSessionTests {
    @Test func confirmedSuggestionUsesOneRoomAndLaterCaptionsUpdateIt() async throws {
        CollabBackend.requests.set([])
        CollabBackend.document.set(nil)
        let credentials = MemoryCredentials()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CollabBackend.self]
        let http = URLSession(configuration: config)
        let account = CollabAccount(configuration: .init(apiURL: URL(string: "https://test.collab.invalid")!,
                                                         webURL: URL(string: "https://web.collab.invalid")!),
                                    credentials: credentials, session: http)
        _ = try await account.service.exchange(code: "fixture")
        account.observeSignIn()
        try #require(await eventually { account.user?.name == "Host" })

        let clock = Box(Date(timeIntervalSince1970: 1_000))
        let llm = FakeLLM()
        llm.answerChunks.set([#"{"suggest":true,"kind":"document","title":"會議決議","instruction":"整理目前決議"}"#])
        let session = CollabSession(account: account, title: "Test", now: { clock.get }, makeLLM: { .ready(llm) })
        let captions = LiveCaptions(now: { clock.get })
        captions.set(.live)
        captions.onFinalized = { [weak session] in session?.finalized($0, captionsOn: true) }
        clock.update { $0.addTimeInterval(20) }
        captions.receive(.partial(String(repeating: "字", count: 40)))
        #expect(llm.answerInputs.get.isEmpty)
        captions.receive(.final(String(repeating: "字", count: 40)))
        try #require(await eventually { session.suggestion != nil })
        session.accept(suggestion: try #require(session.suggestion))
        #expect(session.state == .confirmingStart)
        #expect(!CollabBackend.requests.get.contains("/v1/rooms"))

        llm.answerChunks.set([
            #"{"op":"create","id":"model-id","kind":"document","title":"會議決議","source":"command"}"# + "\n",
            #"{"op":"appendText","id":"model-id","field":"markdown","text":"原有決議"}"# + "\n",
            #"{"op":"done","id":"model-id"}"#,
        ])
        session.startSharing()
        try #require(await eventually { session.commandStatus == .completed("會議決議") })
        let document = try #require(CollabBackend.document.get)
        #expect(document.id != "model-id")
        #expect(document.source == .suggestion)
        #expect(document.content == "原有決議")
        #expect(session.room?.roomId == "room")

        llm.answerChunks.set([
            "{\"op\":\"replaceText\",\"id\":\"\(document.id)\",\"field\":\"markdown\",\"text\":\"更新後決議\"}\n",
            "{\"op\":\"done\",\"id\":\"\(document.id)\"}",
        ])
        clock.update { $0.addTimeInterval(90) }
        captions.receive(.final(String(repeating: "新", count: 199)))
        #expect(CollabBackend.document.get?.content == "原有決議")
        captions.receive(.final("字"))
        try #require(await eventually { CollabBackend.document.get?.content == "更新後決議" })
        #expect(CollabBackend.requests.get.filter { $0 == "/v1/rooms" }.count == 1)
        await session.end()?.value
        #expect(session.state == .ended)
        #expect(CollabBackend.requests.get.last == "/v1/rooms/room/end")
    }
}

private final class CollabBackend: URLProtocol, @unchecked Sendable {
    struct Document: Encodable, Sendable {
        let id: String
        let kind = "document"
        let title: String
        let source: CollabSource
        let updatedAt = "1970-01-01T00:17:00Z"
        var building = true
        var content = ""
    }

    static let requests = Box<[String]>([])
    static let document = Box<Document?>(nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requests.update { $0.append(url.path) }
        let response: (Int, Data)
        let user = #"{"id":"test","name":"Host","email":"host@example.invalid"}"#
        switch url.path {
        case "/v1/auth/exchange":
            response = (200, Data("{\"accessToken\":\"test-access\",\"refreshToken\":\"test-refresh\",\"user\":\(user)}".utf8))
        case "/v1/me":
            response = (200, Data("{\"user\":\(user),\"quota\":{\"used\":0,\"limit\":10,\"period\":\"2026-11\"}}".utf8))
        case "/v1/rooms":
            response = (201, Data(#"{"roomId":"room","shareUrl":"https://web.collab.invalid/r/share","hostUrl":"https://web.collab.invalid/r/share#host=code"}"#.utf8))
        case "/v1/rooms/room/components":
            let docs = Self.document.get.map { [$0] } ?? []
            let json = (try? JSONEncoder().encode(docs)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            response = (200, Data("{\"status\":\"live\",\"components\":\(json)}".utf8))
        case "/v1/rooms/room/ops":
            if let ops = try? JSONDecoder().decode([String: [CollabOp]].self, from: body())["ops"] {
                Self.document.update { document in
                    for op in ops {
                        switch op {
                        case .create(let id, _, let title, let source): document = Document(id: id, title: title, source: source)
                        case .appendText(_, _, let text), .replaceText(_, _, let text): document?.content = text
                        case .done: document?.building = false
                        default: break
                        }
                    }
                }
                response = (204, Data())
            } else { response = (400, Data()) }
        case "/v1/rooms/room/end": response = (204, Data())
        default: response = (404, Data())
        }
        let http = HTTPURLResponse(url: url, statusCode: response.0, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !response.1.isEmpty { client?.urlProtocol(self, didLoad: response.1) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func body() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 2048)
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }
}
