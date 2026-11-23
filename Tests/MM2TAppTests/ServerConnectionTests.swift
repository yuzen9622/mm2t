import Foundation
import MM2TProviders
import Testing
@testable import MM2TApp

@Suite(.serialized) struct ServerConnectionTests {
    @Test(arguments: [ServerConnectionDraft.Kind.summaries, .transcription])
    func switchingOriginsDropsTheSavedAuthorization(kind: ServerConnectionDraft.Kind) async throws {
        ServerProbe.requests.set([])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServerProbe.self]
        let session = URLSession(configuration: configuration)
        var draft = ServerConnectionDraft(kind: kind, savedURL: URL(string: "https://a.example/v1")!, savedKey: "old-key")
        draft.address = "https://A.example:443/another-path"
        #expect(draft.key == "old-key")
        draft.address = "https://b.example"
        #expect(draft.key.isEmpty)
        let endpoint = try #require(draft.endpoint)
        switch kind {
        case .summaries:
            _ = try await OpenAICompatibleLLM(baseURL: endpoint, apiKey: Secret(draft.key), model: "", session: session).availableModels()
        case .transcription:
            #expect(await SelfHostedTranscription(baseURL: endpoint, token: Secret(draft.key), session: session).validateKey() == .valid)
        }
        let requests = ServerProbe.requests.get
        #expect(requests.count == (kind == .summaries ? 1 : 2))
        #expect(requests.first?.url?.host() == "b.example")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        draft.key = "new-key"
        draft.address = "https://b.example:8443"
        #expect(draft.key.isEmpty)
        draft.key = "another-key"
        draft.address = "http://b.example:8443"
        #expect(draft.key.isEmpty)
    }
}

private final class ServerProbe: URLProtocol, @unchecked Sendable {
    static let requests = Box<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.update { $0.append(request) }
        let url = request.url!
        let status = url.path.hasSuffix("/transcriptions") ? 405 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
