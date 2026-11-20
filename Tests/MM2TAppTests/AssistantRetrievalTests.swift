import Foundation
@testable import MM2TCore
import Testing
@testable import MM2TApp

@MainActor @Suite struct AssistantRetrievalTests {
    @Test func assignedWorkDoesNotRequireCategoryKeywords() async throws {
        let world = try World()
        var meeting = try await world.recordedMeeting(title: "報價確認")
        let utterance = try #require(meeting.utterances.last)
        meeting.outputs.summary = Summary(decisions: [], discussionPoints: [], actionItems: [
            .init(text: "週五寄送更新的報價單", owner: .me, sources: [utterance.id]),
            .init(text: "整理其他人的文件", owner: SpeakerID("r1"), sources: [utterance.id]),
        ])
        try await world.library.save(meeting)
        try await world.app.searchIndex.rebuild(from: [meeting])
        let llm = FakeLLM()
        llm.decisions.set([assistantDecision("query_actions"), assistantDecision("answer")])
        let engine = AssistantEngine(library: world.library, index: world.app.searchIndex, voiceprints: world.app.voiceprints)
        for await _ in engine.events(question: "我有哪些沒做、會議交代我做的？", previous: [], provider: llm) {}
        let input = try #require(llm.answerInputs.get.last)
        #expect(input.contains("週五寄送更新的報價單"))
        #expect(!input.contains("整理其他人的文件"))
    }

    @Test func archiveListUsesOnlySelectedRecordsEvenWithoutAnIndex() async throws {
        let world = try World()
        let first = try await world.recordedMeeting(title: "參考一")
        let second = try await world.recordedMeeting(title: "參考二")
        _ = try await world.recordedMeeting(title: "未選取")
        let engine = AssistantEngine(library: world.library, index: MeetingIndex(fileURL: world.root.appending(path: "empty.sqlite")),
            voiceprints: world.app.voiceprints, contextBudget: 1)
        let llm = FakeLLM()
        llm.decisions.set([assistantDecision("list_meetings"), #"{"choice":"inventory"}"#])
        var answer = "", ids = Set<MeetingID>()
        for await event in engine.events(question: "列出選取的會議", provider: llm, scope: [first.id, second.id]) {
            if case .answerDelta(let chunk) = event { answer += chunk }
            if case .finished(let sources) = event { ids = Set(sources.map(\.meeting)) }
        }
        #expect(ids == [first.id, second.id])
        #expect(answer.contains("2/2") && !answer.contains("未選取"))
        #expect(llm.answerInputs.get.isEmpty)
    }

    @Test func failedPassageSelectionKeepsOnlyVerifiedSourcesAndReportsProgress() async throws {
        let world = try World()
        _ = try await world.recordedMeeting(title: "第一篇")
        _ = try await world.recordedMeeting(title: "第二篇")
        let llm = FakeLLM()
        llm.decisions.set([assistantDecision("quote_meetings"), #"{"choice":"targeted"}"#, #"{"line":"1"}"#, #"{"line":"999"}"#])
        let engine = AssistantEngine(library: world.library, index: world.app.searchIndex, voiceprints: world.app.voiceprints)
        var answer = "", result: AssistantToolResult?, failed = false
        for await event in engine.events(question: "每篇各摘錄一句關於驗收的原話", provider: llm) {
            switch event {
            case .answerDelta(let chunk): answer += chunk
            case .toolFinished(_, let observed): result = observed
            case .failed(let reason): failed = reason.contains("1/2")
            case .finished: Issue.record("A partial review cannot finish successfully")
            default: break
            }
        }
        let source = try #require(result?.sources.first)
        let record = try await world.library.meeting(source.meeting)
        let utterance = try #require(record.utterances.first)
        #expect(failed && result?.coverage == "1/2")
        #expect(source.utterance == utterance.id && source.time == utterance.range.start)
        #expect(answer.contains("「" + utterance.text + "」"))
    }

    @Test func inventoryDoesNotReplaceAdviceWithATitleList() async throws {
        let world = try World()
        _ = try await world.recordedMeeting(title: "專案訪談")
        let llm = FakeLLM()
        llm.decisions.set([assistantDecision("list_meetings"), #"{"choice":"evidence"}"#, assistantDecision("answer")])
        llm.answerChunks.set(["建議名稱為「訪談」"])
        let engine = AssistantEngine(library: world.library, index: world.app.searchIndex, voiceprints: world.app.voiceprints)
        var answer = ""
        for await event in engine.events(question: "請給我資料夾名稱建議", provider: llm) {
            if case .answerDelta(let text) = event { answer += text }
        }
        #expect(answer == "建議名稱為「訪談」")
        #expect(llm.answerInputs.get.last?.contains("專案訪談") == true)
    }
}
