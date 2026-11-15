import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TProviders

@Suite struct SummaryUpdateTests {
    private let initial = [
        utterance("u1", "r1", 0, "最初甲案是改用 Kubernetes；乙案是維持現況"),
        utterance("u2", "r2", 10, "目前採乙案，明天下午三點由第一位寄報告，另外通知客戶"),
    ]
    private let tail = utterance("u3", "r2", 20, "恢復最開始甲案。報告改由我後天下午四點寄，通知客戶取消")
    private let early = #"{"headline":"先維持現況","title":"部署方案","decisions":[{"text":"採乙案","sources":["u2"]}],"discussionPoints":[],"actionItems":[{"text":"明天下午三點寄報告","owner":"r1","sources":["u2"],"dueDate":"2026-11-15T15:00:00+08:00"},{"text":"通知客戶","owner":"r2","sources":["u2"],"dueDate":null}]}"#
    private let emptyChange: [String: Any] = ["remove": [], "replace": [], "append": []]

    private func request(_ utterances: [LLMUtterance]) -> SummaryRequest {
        SummaryRequest(transcript: LLMTranscript(utterances: utterances), prioritized: [],
                       meetingStartedAt: Date(timeIntervalSince1970: 1_794_621_600), timeZoneIdentifier: "Asia/Taipei")
    }

    private func changes(action: [String: Any]? = nil) throws -> String {
        let value: [String: Any] = [
            "headline": NSNull(), "title": NSNull(), "decisions": emptyChange,
            "discussionPoints": emptyChange, "actionItems": action ?? emptyChange,
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private var updatedAction: [String: Any] {
        ["text": "後天下午四點寄報告", "owner": "r2", "sources": ["u2", "u3"], "dueDate": "2026-11-16T16:00:00+08:00"]
    }

    @Test func restoresAnOmittedEarlyProposalFromTheFullSourceAndAppliesEveryActionChange() async throws {
        let delta = #"{"headline":"改採甲案","title":null,"decisions":{"remove":[],"replace":[{"index":0,"item":{"text":"改用 Kubernetes","sources":["u1","u3"]}}],"append":[]},"discussionPoints":{"remove":[],"replace":[],"append":[{"text":"重新採用最初甲案","sources":["u1","u3"]}]},"actionItems":{"remove":[1],"replace":[{"index":0,"item":{"text":"後天下午四點寄報告","owner":"r2","sources":["u2","u3"],"dueDate":"2026-11-16T16:00:00+08:00"}}],"append":[]}}"#
        let early = self.early
        let server = StubServer { request in .status(200, Fixture.gemini(request.geminiSystem.contains("只輸出異動") ? delta : early)) }
        let llm = GeminiLLM(apiKey: "test", session: server.session).forRecording()
        _ = try await llm.summarize(request(initial))
        let summary = try await llm.summarize(request(initial + [tail]))
        #expect(summary.headline == "改採甲案")
        #expect(summary.title == "部署方案")
        #expect(summary.decisions == [SourcedText(text: "改用 Kubernetes", sources: [UtteranceID("u1"), UtteranceID("u3")])])
        #expect(summary.discussionPoints.count == 1)
        #expect(summary.actionItems.count == 1)
        #expect(summary.actionItems[0].owner == SpeakerID("r2"))
        #expect(summary.actionItems[0].due?.dateComponents.hour == 16)
        #expect(summary.actionItems[0].due?.dateComponents.day == 16)
        #expect(server.requests.count == 2)
        let update = try #require(server.requests.last)
        #expect(initial.allSatisfy { update.geminiInput.contains($0.text) })
        #expect(update.geminiInput.contains("前次摘要") && update.geminiInput.contains("新增尾段"))
        #expect(update.geminiInput.contains(#""index":0"#))
    }

    @Test(arguments: ["duplicateRemove", "overlap", "duplicateReplace", "negative", "outOfRange", "emptySources", "inventedSource", "unknownOwner", "invalidDeadline", "missingDeadline"])
    func rejectsMalformedChangesAndRegeneratesFromTheCompleteTranscript(_ fault: String) async throws {
        var action = updatedAction
        if fault == "emptySources" { action["sources"] = [String]() }
        if fault == "inventedSource" { action["sources"] = ["u999"] }
        if fault == "unknownOwner" { action["owner"] = "r999" }
        if fault == "invalidDeadline" { action["dueDate"] = "tomorrow" }
        if fault == "missingDeadline" { action.removeValue(forKey: "dueDate") }
        let index = fault == "negative" ? -1 : fault == "outOfRange" ? 2 : 0
        let replacement: [String: Any] = ["index": index, "item": action]
        let patch: [String: Any] = [
            "remove": fault == "duplicateRemove" ? [1, 1] : fault == "overlap" ? [0] : [],
            "replace": fault == "duplicateReplace" ? [replacement, replacement] : [replacement], "append": [],
        ]
        let delta = try changes(action: patch)
        let early = self.early
        let fallback = #"{"headline":"完整重算","title":"完整來源","decisions":[],"discussionPoints":[],"actionItems":[]}"#
        let server = StubServer { request in
            let output = request.geminiSystem.contains("只輸出異動") ? delta : request.geminiInput.contains("[u3]") ? fallback : early
            return .status(200, Fixture.gemini(output))
        }
        let llm = GeminiLLM(apiKey: "test", session: server.session).forRecording()
        _ = try await llm.summarize(request(initial))
        let final = try await llm.summarize(request(initial + [tail]))
        #expect(final.headline == "完整重算")
        #expect(final.actionItems.isEmpty)
        #expect(server.requests.count == 3)
        #expect(server.requests[1].geminiSystem.contains("只輸出異動"))
        #expect(!server.requests[2].geminiSystem.contains("只輸出異動"))
        #expect(initial.allSatisfy { server.requests[2].geminiInput.contains($0.text) })
        #expect(try await llm.summarize(request(initial + [tail])) == final)
        #expect(server.requests.count == 3)
    }

    @Test func fallbackFailureDoesNotReturnTheOldSummaryAsIfComplete() async throws {
        let early = self.early
        let invalid = try changes(action: ["remove": [99], "replace": [], "append": []])
        let server = StubServer { request in
            if request.geminiSystem.contains("只輸出異動") { return .status(200, Fixture.gemini(invalid)) }
            if request.geminiInput.contains("[u3]") { return .status(401, "{}") }
            return .status(200, Fixture.gemini(early))
        }
        let llm = GeminiLLM(apiKey: "test", session: server.session).forRecording()
        _ = try await llm.summarize(request(initial))
        await #expect(throws: ProviderError(.gemini, .invalidCredential)) {
            try await llm.summarize(request(initial + [tail]))
        }
        #expect(server.requests.count == 3)
    }

    @Test(arguments: ["speaker", "id", "text", "highlight", "date", "timezone", "priority", "glossary"])
    func anIncompatiblePrefixUsesFullGeneration(_ field: String) async throws {
        let early = self.early
        let server = StubServer { _ in .status(200, Fixture.gemini(early)) }
        let llm = GeminiLLM(apiKey: "test", session: server.session).forRecording()
        let before = request(initial)
        _ = try await llm.summarize(before)
        var modified = initial
        modified[0] = utterance(field == "id" ? "new-id" : "u1", field == "speaker" ? "r2" : "r1", 0,
                                field == "text" ? "修正原文" : initial[0].text, highlighted: field == "highlight")
        var transcript = LLMTranscript(utterances: modified + [tail])
        if field == "glossary" { transcript.glossary = ["新術語"] }
        let after = SummaryRequest(transcript: transcript, prioritized: field == "priority" ? [modified[0]] : [],
            meetingStartedAt: field == "date" ? before.meetingStartedAt?.addingTimeInterval(86_400) : before.meetingStartedAt,
            timeZoneIdentifier: field == "timezone" ? "UTC" : before.timeZoneIdentifier)
        _ = try await llm.summarize(after)
        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy { !$0.geminiSystem.contains("只輸出異動") })
    }

    @Test func olderAsyncCompletionCannotReplaceANewerCheckpoint() async {
        let store = SummaryCheckpointStore()
        let old = await store.begin()
        let newer = await store.begin()
        let oldSummary = Summary(headline: "old", decisions: [], discussionPoints: [], actionItems: [])
        let newSummary = Summary(headline: "new", decisions: [], discussionPoints: [], actionItems: [])
        await store.accept(newSummary, for: request(initial + [tail]), ticket: newer)
        await store.accept(oldSummary, for: request(initial), ticket: old)
        let current = await store.begin()
        #expect(current.previous?.summary.headline == "new")
        #expect(current.previous?.request.transcript.utterances.count == 3)
        await store.accept(oldSummary, for: request(initial), ticket: current)
        #expect(await store.begin().previous?.summary.headline == "new")
    }
}
