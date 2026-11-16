import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TApp

@MainActor @Suite struct AssistantTasksTests {
    @Test func ownershipAndCompletionAreNotKeywordSearches() async throws {
        let world = try World()
        var meeting = try await world.recordedMeeting()
        let source = try #require(meeting.utterances.last?.id)
        let mine = Summary.ActionItem(text: "寄出報價", owner: .me, sources: [source])
        meeting.outputs.summary = Summary(decisions: [], discussionPoints: [], actionItems: [
            mine, .init(text: "處理文件", owner: SpeakerID("r1"), sources: [source]),
            .init(text: "待分派", owner: nil, sources: [source]),
        ])
        let query = AssistantTaskQuery()
        let page = try AssistantTasks.page(query, meetings: [meeting], names: [:], user: nil, status: .init())
        #expect(page.rows.map(\.item.text) == ["寄出報價"])
        #expect(page.identityGap)
        let key = "\(meeting.id)#0"
        let done = TodoSnapshot(done: [key], anchors: [key: AssistantTaskRef.fingerprint(mine)])
        #expect(try AssistantTasks.page(query, meetings: [meeting], names: [:], user: nil, status: done).rows.isEmpty)
        meeting.outputs.summary = Summary(decisions: [], discussionPoints: [], actionItems: [
            .init(text: "新的交辦", owner: .me, sources: [source]), mine,
        ])
        let changed = try AssistantTasks.page(query, meetings: [meeting], names: [:], user: nil, status: done)
        #expect(changed.rows.count == 2)
        #expect(changed.rows.allSatisfy { $0.status == .needsConfirmation })
        #expect(page.rows[0].ref.resolve(in: meeting) == 1)
    }

    @Test func legacyMarksStayVisibleAndCorruptStatusIsNotOverwritten() async throws {
        let world = try World()
        var meeting = try await world.recordedMeeting()
        let source = try #require(meeting.utterances.last?.id)
        meeting.outputs.summary = Summary(decisions: [], discussionPoints: [], actionItems: [
            .init(text: "尚待確認的交辦", owner: .me, sources: [source]),
        ])
        let page = try AssistantTasks.page(.init(), meetings: [meeting], names: [:], user: nil,
                                          status: .init(done: ["\(meeting.id)#0"]))
        #expect(page.rows.count == 1)
        #expect(page.rows.first?.status == .legacyDone)
        let file = world.root.appending(path: "corrupt-status/todos.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("broken file".utf8)
        try bytes.write(to: file)
        let status = TodoStatus(file: file)
        status.toggle("new-task", anchor: "fingerprint")
        #expect(status.storageError != nil)
        #expect(status.done.isEmpty)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func duplicateTasksKeepDistinctReferences() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        let uid = try #require(meeting.utterances.first?.id)
        var ledger = AssistantLedger()
        let first = AssistantSource(id: "", meeting: meeting.id, utterance: uid, title: "Same", date: Date(),
            quote: "same", speaker: "me", time: 0, task: .init(meeting: meeting.id, index: 0, fingerprint: "same", sources: [uid]))
        var second = first
        second.task = .init(meeting: meeting.id, index: 1, fingerprint: "same", sources: [uid])
        let a = ledger.register(first)
        let b = ledger.register(second)
        #expect(a.id != b.id)
        #expect(ledger.sources.first { $0.id == a.id }?.task?.index == 0)
    }

    @Test func taskLoopAdvancesPagesWithoutModelCopyingCursor() async throws {
        let world = try World()
        var meeting = try await world.recordedMeeting()
        let source = try #require(meeting.utterances.last?.id)
        meeting.outputs.summary = Summary(decisions: [], discussionPoints: [], actionItems: (0..<47).map {
            .init(text: "需處理的工作\($0)", owner: .me, sources: [source])
        })
        try await world.library.save(meeting)
        let llm = FakeLLM()
        llm.decisions.set(Array(repeating: assistantDecision("query_actions"), count: 3) + [assistantDecision("answer")])
        let engine = AssistantEngine(library: world.library, index: world.app.searchIndex, voiceprints: world.app.voiceprints)
        var counts: [Int] = []
        for await event in engine.events(question: "我的所有工作", provider: llm) {
            if case .toolFinished(_, let result) = event { counts.append(result.count) }
        }
        #expect(counts == [20, 20, 7])
        #expect(llm.answerInputs.get.last?.contains("需處理的工作46") == true)
        let tiny = AssistantEngine(library: world.library, index: world.app.searchIndex, voiceprints: world.app.voiceprints, contextBudget: 1)
        llm.decisions.set([assistantDecision("query_actions"), assistantDecision("answer")])
        var clipped: AssistantToolResult?
        var ledger = AssistantLedger()
        for await event in tiny.events(question: "我的所有工作", provider: llm) {
            if case .toolFinished(_, let result) = event { clipped = result }
            if case .ledger(let value) = event { ledger = value }
        }
        #expect(clipped?.count == 0)
        #expect(clipped?.coverage.contains(":0;") == true)
        #expect(clipped?.coverage.contains("clipped=true") == true)
        #expect(ledger.sources.isEmpty)
    }

    @Test func paginationHasCoverageAndRejectsStaleCursors() async throws {
        let world = try World()
        var meeting = try await world.recordedMeeting()
        let source = try #require(meeting.utterances.last?.id)
        meeting.outputs.summary = Summary(decisions: [], discussionPoints: [], actionItems: (0..<47).map {
            .init(text: "工作 \($0)", owner: .me, sources: [source])
        })
        var query = AssistantTaskQuery()
        let first = try AssistantTasks.page(query, meetings: [meeting], names: [:], user: nil, status: .init())
        #expect(first.total == 47 && first.rows.count == 20)
        query.cursor = first.nextCursor
        let second = try AssistantTasks.page(query, meetings: [meeting], names: [:], user: nil, status: .init())
        #expect(second.offset == 20 && second.rows.count == 20)
        query.cursor = second.nextCursor
        let last = try AssistantTasks.page(query, meetings: [meeting], names: [:], user: nil, status: .init())
        #expect(last.rows.count == 7 && last.nextCursor == nil)
        #expect(Set((first.rows + second.rows + last.rows).map(\.ref.index)).count == 47)
        #expect(throws: AssistantQueryError.self) {
            try AssistantTasks.page(query, meetings: [meeting], names: [:], user: nil, status: .init(done: ["\(meeting.id)#0"]))
        }
    }
}
