import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TProviders

@Suite struct SelfHostedTranscriptionTests {
    let base = URL(string: "http://100.64.0.7:8000")!

    func healthy(_ upload: @escaping @Sendable (StubServer.Request) -> StubServer.Reply) -> StubServer {
        StubServer { $0.url.path == "/healthz" ? .status(200, Fixture.health) : upload($0) }
    }

    @Test func sendsTheServerContract() async throws {
        let server = healthy { _ in .status(200, Fixture.selfHosted) }
        let provider = SelfHostedTranscription(baseURL: base, token: "tok", languageCode: "zh-TW", session: server.session)
        _ = try await provider.transcribe(audio: try audioFile("mic.m4a"), hints: ["王小明", " ", "Kubernetes"], labelSpeakers: false)

        let upload = try #require(server.requests.last)
        #expect(upload.method == "POST")
        #expect(upload.url.absoluteString == "http://100.64.0.7:8000/v1/transcriptions")
        #expect(upload.headers["Authorization"] == "Bearer tok")
        #expect(upload.field("language") == ["zh-TW"])
        let vocabulary = try JSONDecoder().decode([String].self, from: Data(try #require(upload.field("vocabulary").first).utf8))
        #expect(vocabulary == ["王小明", "Kubernetes"])
        #expect(upload.bodyText.contains(#"name="file"; filename="mic.m4a""#))
    }

    @Test func omitsOptionalFieldsAndTokenWhenUnset() async throws {
        let server = healthy { _ in .status(200, Fixture.selfHosted) }
        let provider = SelfHostedTranscription(baseURL: base, token: Secret(""), session: server.session)
        _ = try await provider.transcribe(audio: try audioFile(), hints: [], labelSpeakers: true)

        let upload = try #require(server.requests.last)
        #expect(upload.headers["Authorization"] == nil)
        #expect(upload.field("vocabulary").isEmpty && upload.field("language").isEmpty)
    }

    @Test func offlineServerFailsAtTheHealthCheckWithoutUploading() async throws {
        let server = StubServer { _ in .failure(.timedOut) }
        let provider = SelfHostedTranscription(baseURL: base, token: nil, session: server.session)
        let error = await #expect(throws: TranscriptionError.self) {
            try await provider.transcribe(audio: try audioFile(), hints: [], labelSpeakers: false)
        }
        guard case .unreachable(let message) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(message.contains("Tailscale"))
        #expect(server.requests.map(\.url.path) == ["/healthz"])
    }

    @Test func wrongAddressIsUnreachable() async throws {
        let server = StubServer(status: 404, body: "<html>not found</html>")
        let provider = SelfHostedTranscription(baseURL: base, token: nil, session: server.session)
        await #expect(throws: TranscriptionError.unreachable(ProviderError(.selfHosted, .unreachable).description)) {
            try await provider.transcribe(audio: try audioFile(), hints: [], labelSpeakers: false)
        }
    }

    static let failures: [(status: Int, code: String, says: String)] = [
        (400, "invalid_audio", "無法讀取"),
        (413, "payload_too_large", "大小上限"),
        (401, "unauthorized", "Token 無效"),
        (400, "invalid_vocabulary", "拒絕"),
        (500, "engine_error", "內部錯誤"),
    ]

    @Test(arguments: failures)
    func serverErrorsStopTheChainWithAnActionableMessage(_ failure: (status: Int, code: String, says: String)) async throws {
        let server = healthy { _ in
            .status(failure.status, #"{"error":{"code":"\#(failure.code)","message":"CUDA failed with Traceback ..."}}"#)
        }
        let provider = SelfHostedTranscription(baseURL: base, token: "tok", session: server.session)
        let error = await #expect(throws: TranscriptionError.self) {
            try await provider.transcribe(audio: try audioFile(), hints: [], labelSpeakers: false)
        }
        guard case .failed(let message) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(message.contains(failure.says))
        #expect(!message.contains("Traceback"))
    }

    @Test func segmentWithoutWordTimingsFallsBackToTheSegment() throws {
        let body = #"{"model":"m","language":"zh","duration":3,"segments":[{"start":0.5,"end":2.5,"text":" 好的","words":[]}]}"#
        #expect(try SelfHostedTranscription.parse(Data(body.utf8)) == [TimedWord("好的", 0.5, 2.5)])
    }

    @Test func validateToken() async throws {
        let good = healthy { _ in .status(405, #"{"detail":"Method Not Allowed"}"#) }
        #expect(await SelfHostedTranscription(baseURL: base, token: "tok", session: good.session).validateKey() == .valid)
        #expect(good.requests.last?.method == "GET")
        #expect(good.requests.last?.headers["Authorization"] == "Bearer tok")

        let bad = healthy { _ in .status(401, #"{"error":{"code":"unauthorized","message":"missing or invalid bearer token"}}"#) }
        guard case .rejected(let wrong) = await SelfHostedTranscription(baseURL: base, token: "tok", session: bad.session).validateKey() else {
            Issue.record("401 should reject"); return
        }
        #expect(wrong.contains("Token 無效"))
        guard case .rejected(let missing) = await SelfHostedTranscription(baseURL: base, token: nil, session: bad.session).validateKey() else {
            Issue.record("401 without a token should reject"); return
        }
        #expect(missing.contains("MM2T_SERVER_TOKEN"))

        let offline = StubServer { _ in .failure(.cannotConnectToHost) }
        guard case .inconclusive = await SelfHostedTranscription(baseURL: base, token: "tok", session: offline.session).validateKey() else {
            Issue.record("offline is not a verdict"); return
        }
    }
}
