import Foundation
import MM2TProviders
import Testing
@testable import MM2TApp

@Suite(.serialized) struct ServerConnectionTests {
    @Test(arguments: [ServerConnectionDraft.Kind.summaries, .transcription])
    func switchingOriginsDropsTheSavedAuthorization(kind: ServerConnectionDraft.Kind) async throws {
        ServerProbe.status.set(405)
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

    @MainActor @Test(arguments: [405, 401, 402, -1])
    func hostedSetupRecheckChecksOnlySelectedHostedJobs(status: Int) async throws {
        ServerProbe.status.set(status)
        ServerProbe.requests.set([])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServerProbe.self]
        let validator = LiveKeyValidator(session: URLSession(configuration: configuration))
        let api = URL(string: "https://plan.example/proxy")!
        let world = try World(setupValidator: validator, collabConfiguration: .init(apiURL: api, webURL: api))
        try world.credentials.save(Secret(#"{"apiURL":"https://plan.example/proxy","tokens":{"accessToken":"plan-token","refreshToken":"refresh"}}"#), for: .collabAccount)
        world.app.settings.settings.transcriptionService = .mm2t
        world.app.setup.recheck()
        await world.app.setup.waitForHostedChecks()
        #expect(ServerProbe.requests.get.map { $0.url?.path } == ["/proxy/v1/hosted/stt/v1/transcriptions"])

        ServerProbe.requests.set([])
        world.app.settings.settings.summaryService = .mm2t
        world.app.setup.recheck()
        await world.app.setup.waitForHostedChecks()
        let requests = ServerProbe.requests.get
        #expect(requests.map { $0.url?.path } == ["/proxy/v1/hosted/stt/v1/transcriptions", "/proxy/v1/hosted/llm/models"])
        #expect(requests.map(\.httpMethod) == ["GET", "GET"])
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer plan-token", "Bearer plan-token"])
        let message: String? = switch status {
        case 401: "Sign in to use your mm2t plan."
        case 402: "Your mm2t plan has no minutes left this month."
        case -1: ProviderError(.mm2tPlan, .unreachable).description
        default: nil
        }
        #expect(world.app.setup.issues == (message.map { [.hostedPlanCheck(.transcription, $0), .hostedPlanCheck(.summaries, $0)] } ?? []))
    }

    @Test(arguments: [HostedPlanJob.transcription, .summaries], [true, false])
    func hostedValidationRenewsRejectedToken(job: HostedPlanJob, renewalSucceeds: Bool) async throws {
        ServerProbe.requests.set([])
        ServerProbe.renewalSucceeds.set(renewalSucceeds)
        defer { ServerProbe.renewalSucceeds.set(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServerProbe.self]
        let session = URLSession(configuration: configuration)
        let api = URL(string: "https://plan.example/proxy")!
        let stored = Box<Secret?>(Secret(#"{"apiURL":"https://plan.example/proxy","tokens":{"accessToken":"expired-token","refreshToken":"refresh"}}"#))
        let account = CollabService(baseURL: api, session: session, load: { stored.get }, save: { stored.set($0) })
        let validator = LiveKeyValidator(session: session, account: account)
        let url = PipelineSetup.hostedURL(api, job: job.rawValue)
        let request: KeyValidation = switch job {
        case .transcription: .hostedTranscription(url: url, token: "expired-token")
        case .summaries: .hostedSummaries(url: url, token: "expired-token")
        }

        let result = await validator.validate(request)

        #expect(result == (renewalSucceeds ? .valid : .rejected("Sign in to use your mm2t plan.")))
        let requests = ServerProbe.requests.get
        let endpoint = job == .transcription ? "/proxy/v1/hosted/stt/v1/transcriptions" : "/proxy/v1/hosted/llm/models"
        #expect(requests.map { $0.url?.path } == [endpoint, "/proxy/v1/auth/refresh"] + (renewalSucceeds ? [endpoint] : []))
        #expect(requests.map(\.httpMethod) == ["GET", "POST"] + (renewalSucceeds ? ["GET"] : []))
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer expired-token")
        if renewalSucceeds {
            #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer renewed-token")
        }
    }
}

private final class ServerProbe: URLProtocol, @unchecked Sendable {
    static let requests = Box<[URLRequest]>([])
    static let status = Box(405)
    static let renewalSucceeds = Box<Bool?>(nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.update { $0.append(request) }
        let url = request.url!
        let status: Int
        let body: String
        if let renewalSucceeds = Self.renewalSucceeds.get {
            if url.path.hasSuffix("/auth/refresh") {
                status = renewalSucceeds ? 200 : 401
                body = renewalSucceeds
                    ? #"{"accessToken":"renewed-token","refreshToken":"new-refresh","user":{"id":"1","name":"Test","email":"test@example.test"}}"#
                    : #"{"error":"unauthorized"}"#
            } else {
                let renewed = request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed-token"
                status = renewed ? (url.path.hasSuffix("/models") ? 200 : 405) : 401
                body = #"{"data":[]}"#
            }
        } else {
            status = if url.path.hasSuffix("/healthz") || (url.path.hasSuffix("/models") && Self.status.get == 405) {
                200
            } else { Self.status.get }
            body = #"{"data":[]}"#
        }
        if status == -1 {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
