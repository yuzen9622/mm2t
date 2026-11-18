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
}
