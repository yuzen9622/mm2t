import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TProviders

/// Stub responses verify prompt delivery and output preservation, not model compliance.
@Suite struct SummaryFidelityTests {
    private let initial = [
        utterance("u1", "r1", 0, "如果需要範例我可以提供，現在先不要列固定交付"),
        utterance("u2", "r2", 10, "我會在下次會議前整理測試報告"),
        utterance("u3", "r3", 20, "下次會議確定十二月三日上午，確切時間稍後確認"),
    ]
    private let confirmation = utterance("u4", "r3", 30, "十二月三日這場就訂上午十點半，時間確定了")
    private let offer = SourcedText(text: "需要時可提供範例，尚未承諾固定交付", sources: [UtteranceID("u1")])

    private func request(_ utterances: [LLMUtterance]) -> SummaryRequest {
        SummaryRequest(transcript: LLMTranscript(utterances: utterances), prioritized: [],
                       meetingStartedAt: ISO8601DateFormatter().date(from: "2026-11-28T09:00:00+08:00")!,
                       timeZoneIdentifier: "Asia/Taipei")
    }

    @Test(arguments: [false, true])
    func fullAndIncrementalRequestsPreserveConditionalOffersAndConfirmedMeetingDeadlines(_ recording: Bool) async throws {
        let early = #"{"decisions":[],"discussionPoints":[{"text":"需要時可提供範例，尚未承諾固定交付","sources":["u1"]}],"actionItems":[{"text":"下次會議前整理測試報告","owner":"r2","sources":["u2","u3"],"dueDate":"2026-12-03"}]}"#
        let final = #"{"decisions":[],"discussionPoints":[{"text":"需要時可提供範例，尚未承諾固定交付","sources":["u1"]}],"actionItems":[{"text":"下次會議前整理測試報告","owner":"r2","sources":["u2","u3","u4"],"dueDate":"2026-12-03T10:30:00+08:00"}]}"#
        let delta = #"{"headline":null,"title":null,"decisions":{"remove":[],"replace":[],"append":[]},"discussionPoints":{"remove":[],"replace":[],"append":[]},"actionItems":{"remove":[],"replace":[{"index":0,"item":{"text":"下次會議前整理測試報告","owner":"r2","sources":["u2","u3","u4"],"dueDate":"2026-12-03T10:30:00+08:00"}}],"append":[]}}"#
        let server = StubServer { request in
            let output = request.geminiSystem.contains("只輸出異動") ? delta
                : request.geminiInput.contains("[u4]") ? final : early
            return .status(200, Fixture.gemini(output))
        }
        let base = GeminiLLM(apiKey: "test", session: server.session)
        let llm = recording ? base.forRecording() : base
        if recording {
            let previous = try await llm.summarize(request(initial))
            #expect(previous.actionItems.first?.due?.hasTime == false)
        }
        let complete = initial + [confirmation]
        let summary = try await llm.summarize(request(complete))
        #expect(summary.decisions.isEmpty)
        #expect(summary.discussionPoints == [offer])
        #expect(summary.actionItems.count == 1)
        let action = try #require(summary.actionItems.first)
        #expect(action.text == "下次會議前整理測試報告")
        #expect(action.owner == SpeakerID("r2"))
        #expect(action.sources == ["u2", "u3", "u4"].map(UtteranceID.init))
        #expect(action.due?.hasTime == true)
        #expect(action.due?.dateComponents.day == 3)
        #expect(action.due?.dateComponents.hour == 10)
        #expect(action.due?.dateComponents.minute == 30)
        #expect(server.requests.count == (recording ? 2 : 1))
        let sent = try #require(server.requests.last)
        #expect(complete.allSatisfy { sent.geminiInput.contains($0.text) })
        #expect(sent.geminiSystem.contains("需要時可提供") && sent.geminiSystem.contains("不能改成無條件"))
        #expect(sent.geminiSystem.contains("同時引用任務約定、會議日期與時間確認"))
        if recording {
            #expect(sent.geminiSystem.contains("不能因任務文字沒變就保留舊 dueDate"))
        }
    }

    @Test(arguments: [false, true])
    func ambiguousNumericVersionsDoNotSupplyADeadlineTime(_ knownDate: Bool) async throws {
        let date = knownDate ? "\"2026-12-03\"" : "null"
        let output = """
        {"decisions":[],"discussionPoints":[],"actionItems":[{"text":"下次會議前整理版本比較","owner":"r2","sources":["u1","u2"],"dueDate":\(date)}]}
        """
        let server = StubServer(status: 200, body: Fixture.gemini(output))
        let source = [
            utterance("u1", "r2", 0, "下次會議前整理版本比較，目前版本是 10.5"),
            utterance("u2", "r3", 10, knownDate ? "下次會議確定十二月三日下午，幾點還沒確定" : "下次會議日期和時間都還沒確定"),
        ]
        let summary = try await GeminiLLM(apiKey: "test", session: server.session).summarize(request(source))
        let action = try #require(summary.actionItems.first)
        #expect(action.due?.hasTime == (knownDate ? false : nil))
        #expect(action.due?.dateComponents.hour == nil)
        let sent = try #require(server.requests.last)
        #expect(sent.geminiSystem.contains("一般小數、數量、金額或版本號不得當成時間"))
        #expect(sent.geminiSystem.contains("前後文足以唯一確定幾點幾分"))
        #expect(sent.geminiInput.contains("版本是 10.5"))
    }

    @Test(arguments: [false, true])
    func explicitNullDoesNotTurnTheDateOfAnEventIntoATaskDeadline(_ recording: Bool) async throws {
        let early = #"{"decisions":[],"discussionPoints":[],"actionItems":[{"text":"今天收到的資料有問題，請反映","owner":"r1","sources":["u1"],"dueDate":"2026-11-28"}]}"#
        let final = #"{"decisions":[],"discussionPoints":[],"actionItems":[{"text":"今天收到的資料有問題，請反映","owner":"r1","sources":["u1","u2"],"dueDate":null}]}"#
        let delta = #"{"headline":null,"title":null,"decisions":{"remove":[],"replace":[],"append":[]},"discussionPoints":{"remove":[],"replace":[],"append":[]},"actionItems":{"remove":[],"replace":[{"index":0,"item":{"text":"今天收到的資料有問題，請反映","owner":"r1","sources":["u1","u2"],"dueDate":null}}],"append":[]}}"#
        let server = StubServer { request in
            .status(200, Fixture.gemini(request.geminiSystem.contains("只輸出異動") ? delta
                : request.geminiInput.contains("[u2]") ? final : early))
        }
        let base = GeminiLLM(apiKey: "test", session: server.session)
        let llm = recording ? base.forRecording() : base
        let first = [utterance("u1", "r1", 0, "今天收到的資料有問題，請反映")]
        if recording { _ = try await llm.summarize(request(first)) }
        let summary = try await llm.summarize(request(first + [utterance("u2", "r1", 10, "沒有另訂反映的截止日")]))
        #expect(summary.actionItems.first?.text.contains("今天收到") == true)
        #expect(summary.actionItems.first?.due == nil)
        #expect(server.requests.last?.geminiSystem.contains("區分事件日期與任務期限") == true)
    }

    @Test(arguments: ["missing", "invalid"])
    func aFreshSummaryMustProvideANullOrValidStructuredDeadline(_ fault: String) async throws {
        let field = fault == "missing" ? "" : #", "dueDate":"tomorrow""#
        let output = """
        {"decisions":[],"discussionPoints":[],"actionItems":[{"text":"今天收到的資料有問題，請反映","owner":"r1","sources":["u1"]\(field)}]}
        """
        let server = StubServer(status: 200, body: Fixture.gemini(output))
        let llm = GeminiLLM(apiKey: "test", session: server.session)
        await #expect(throws: ProviderError(.gemini, .malformedResponse)) {
            try await llm.summarize(request([utterance("u1", "r1", 0, "今天收到的資料有問題，請反映")]))
        }
    }
}
