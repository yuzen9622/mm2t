import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TProviders

@Suite struct HostedPlanProviderTests {
    @Test(arguments: [401, 402])
    func transcriptionSendsBearerAndReportsPlanFailure(status: Int) async throws {
        let server = StubServer(status: status, body: "{}")
        let client = SelfHostedTranscription(baseURL: URL(string: "https://hosted.example/v1/hosted/stt")!,
                                              token: "test-session", session: server.session, hostedPlan: true)
        let audio = try audioFile()
        let expected = status == 401 ? "Sign in to use your mm2t plan." : "Your mm2t plan has no minutes left this month."
        await #expect(throws: TranscriptionError.failed(expected)) {
            try await client.transcribe(audio: audio, hints: [], labelSpeakers: false)
        }
        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.url.path == "/v1/hosted/stt/v1/transcriptions")
        #expect(request.headers["Authorization"] == "Bearer test-session")
    }

    @Test(arguments: [401, 402])
    func summariesSendBearerAndReportPlanFailure(status: Int) async throws {
        let server = StubServer(status: status, body: "{}")
        let client = OpenAICompatibleLLM(baseURL: URL(string: "https://hosted.example/v1/hosted/llm")!,
                                         apiKey: "test-session", model: "mm2t", session: server.session, hostedPlan: true)
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
