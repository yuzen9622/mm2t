import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TProviders

@Suite struct HostedPlanProviderTests {
    @Test(arguments: [401, 402])
    func transcriptionSendsBearerAndReportsPlanFailure(status: Int) async throws {
        let server = StubServer { request in
            switch request.url.path {
            case "/v1/hosted/sessions": .status(201, #"{"id":"lease-1"}"#)
            case "/v1/hosted/sessions/lease-1/finish": .status(200, "{}")
            default: .status(status, "{}")
            }
        }
        let client = HostedTranscription(baseURL: URL(string: "https://hosted.example/v1/hosted/stt")!,
                                         authorization: .fixed("test-session"), leases: HostedLeases(), session: server.session)
        let audio = try audioFile()
        try wav((0..<16_000).map { $0 % 32 < 16 ? Float(0.2) : Float(-0.2) }, sampleRate: 16_000).write(to: audio)
        let expected = status == 401 ? "Sign in to use your mm2t plan." : "Your mm2t plan has no minutes left this month."
        await #expect(throws: TranscriptionError.failed(expected)) {
            try await client.transcribe(audio: audio, hints: [], labelSpeakers: false)
        }
        let uploads = server.requests.filter { $0.url.path == "/v1/hosted/stt/v1/transcriptions" }
        #expect(uploads.count == 1)
        #expect(uploads.first?.headers["Authorization"] == "Bearer test-session")
    }

    @Test(arguments: [401, 402])
    func summariesSendBearerAndReportPlanFailure(status: Int) async throws {
        let server = StubServer(status: status, body: "{}")
        let client = OpenAICompatibleLLM(baseURL: URL(string: "https://hosted.example/v1/hosted/llm")!,
                                         apiKey: nil, model: "mm2t", session: server.session, authorization: .fixed("test-session"))
        let expected = ProviderError(.mm2tPlan, status == 401 ? .invalidCredential : .outOfCredit)
        await #expect(throws: expected) { try await client.rewrite("hello", instruction: "shorter") }
        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.url.path == "/v1/hosted/llm/chat/completions")
        #expect(request.headers["Authorization"] == "Bearer test-session")
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["model"] as? String == "mm2t")
    }
}
