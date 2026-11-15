import Foundation
@testable import MM2TCore
import Testing
@testable import MM2TApp

@MainActor @Suite struct AssistantTests {
    @Test func eventOrderAndCitations() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting(title: "預算")
        try await world.app.searchIndex.rebuild(from: [meeting])
        let llm = FakeLLM()
        llm.planJSON.set(plan(queries: ["大家好"]))
        let engine = AssistantEngine(library: world.library, index: world.app.searchIndex, voiceprints: world.app.voiceprints)
        var order: [String] = []
        var sources: [AssistantSource] = []
        for await event in engine.events(question: "What happened?", previous: [], provider: llm) {
            switch event {
            case .planStarted: order.append("plan")
            case .planFinished: order.append("planned")
            case .toolStarted(_, let kind, _): order.append(kind == .search ? "search" : "read")
            case .toolFinished: order.append("toolDone")
            case .answerDelta: order.append("delta")
            case .finished(let found): sources = found; order.append("finished")
            case .failed(let reason): Issue.record("\(reason)")
            }
        }
        #expect(order == ["plan", "planned", "search", "toolDone", "read", "toolDone", "delta", "finished"])
        #expect(sources.map(\.id) == ["m1", "m1.u1"])
        #expect(sources.allSatisfy { $0.meeting == meeting.id })
        #expect(sources.last?.utterance == meeting.utterances.first?.id)
        #expect(llm.answerInputs.get.first?.contains("{{speaker:") == false)
    }

    @Test func peopleDatesAndFiltersOnlyReachRealIndex() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting(title: "Budget")
        try await world.app.voiceprints.enrollUser(name: "Alex", embeddings: [])
        let user = try #require(await world.app.voiceprints.user())
        try await world.app.searchIndex.rebuild(from: [meeting], user: user.id)
        let llm = FakeLLM()
        let day = AssistantEngine.day(meeting.metadata.startedAt)
        llm.planJSON.set(plan(queries: [], people: ["Alex"], from: day, to: day))
        let engine = AssistantEngine(library: world.library, index: world.app.searchIndex, voiceprints: world.app.voiceprints)
        var counts: [Int] = []
        for await event in engine.events(question: "Alex today", previous: [], provider: llm) {
            if case .toolFinished(_, let result) = event { counts.append(result.count) }
        }
        #expect(counts == [1, 1])
        llm.planJSON.set(plan(queries: [], people: ["Alex"], from: "2000-01-01", to: "2000-01-01"))
        counts = []
        for await event in engine.events(question: "Alex then", previous: [], provider: llm) {
            if case .toolFinished(_, let result) = event { counts.append(result.count) }
        }
        #expect(counts == [0])
        let other = try await world.app.voiceprints.addPerson(name: "Other")
        #expect(await world.app.voiceprints.names()[other] == "Other")
        llm.planJSON.set(plan(queries: [], people: ["Other"]))
        counts = []
        for await event in engine.events(question: "Other", previous: [], provider: llm) {
            if case .toolFinished(_, let result) = event { counts.append(result.count) }
        }
        #expect(counts == [0])
    }

    @Test func capBudgetAndNoLookup() async throws {
        let world = try World()
        for number in 0..<10 { _ = try await world.recordedMeeting(title: "Budget \(number)") }
        try await world.app.searchIndex.rebuild(from: world.library.list())
        let llm = FakeLLM()
        llm.planJSON.set(plan(queries: ["Budget"]))
        let engine = AssistantEngine(library: world.library, index: world.app.searchIndex, voiceprints: world.app.voiceprints)
        var readCount = 0
        for await event in engine.events(question: "Budget", previous: [], provider: llm) {
            if case .toolStarted(_, .read, let args) = event { readCount = args.meetings.count }
        }
        #expect(readCount == 8)
        let tiny = AssistantEngine(library: world.library, index: world.app.searchIndex, voiceprints: world.app.voiceprints, contextBudget: 1)
        for await _ in tiny.events(question: "Budget", previous: [], provider: llm) {}
        #expect(llm.answerInputs.get.last?.hasSuffix("material):\n") == true)
        llm.planJSON.set(plan(queries: [], lookup: false))
        var tools = 0
        for await event in engine.events(question: "Hello", previous: [], provider: llm) {
            if case .toolStarted = event { tools += 1 }
        }
        #expect(tools == 0)
        #expect(llm.answerInputs.get.count == 3)
    }

    @Test func stopSetupAndRetry() async throws {
        let world = try World()
        let llm = FakeLLM()
        llm.planJSON.set(plan(queries: [], lookup: false))
        llm.answerChunks.set(["Partial ", "answer"])
        llm.holdsStream.set(true)
        let engine = AssistantEngine(library: world.library, index: world.app.searchIndex, voiceprints: world.app.voiceprints)
        let model = AssistantModel(engine: engine, build: { .ready(llm) })
        model.send("Question")
        #expect(await eventually { model.turns.last?.answer.text == "Partial answer" })
        model.stop()
        #expect(model.turns.last?.state == .stopped)
        #expect(model.turns.last?.answer.text == "Partial answer")
        #expect(model.turns.last?.answer.batches.count == 1)
        #expect(model.turns.last?.activityExpanded == false)
        #expect(await eventually { llm.streamCancelled.get })
        llm.holdsStream.set(false)
        model.retry()
        #expect(await eventually { model.turns.last?.state == .finished })
        #expect(model.turns.count == 1)
        let setup = AssistantModel(engine: engine, build: { .needsSetup([]) })
        setup.send("Question")
        #expect(setup.turns.last?.state == .needsSetup)
        #expect(setup.turns.last?.steps.isEmpty == true)
    }

    @Test func failedPlanRemainsVisibleAndBudgetDropsWholeItems() async throws {
        let world = try World()
        let llm = FakeLLM()
        llm.failNext.set(["plan"])
        let engine = AssistantEngine(library: world.library, index: world.app.searchIndex, voiceprints: world.app.voiceprints)
        let model = AssistantModel(engine: engine, build: { .ready(llm) })
        model.send("Question")
        #expect(await eventually { !model.isRunning })
        #expect(model.turns.last?.activityExpanded == true)
        guard case .failed = model.turns.last?.steps.last?.state else { Issue.record("Expected a failed plan row"); return }
        #expect(llm.answerInputs.get.isEmpty)
        let meeting = try await world.recordedMeeting(title: "Budget")
        try await world.app.searchIndex.rebuild(from: [meeting])
        let hits = try #require(try await world.app.searchIndex.search(.init(text: "Budget")).first)
        let first = AssistantContext.item(meeting, hits: hits, ordinal: 1, names: [:], user: nil)
        let second = AssistantContext.item(meeting, hits: hits, ordinal: 2, names: [:], user: nil)
        var context = AssistantContext(budget: first.text.count)
        let fits = context.append(first)
        let exceeds = context.append(second)
        #expect(fits && !exceeds)
        #expect(context.text == first.text)
        #expect(context.sources == first.sources)
    }

    @Test func answerFailureAddsAnHonestFailedActivity() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting(title: "Budget")
        try await world.app.searchIndex.rebuild(from: [meeting])
        let llm = FakeLLM()
        llm.planJSON.set(plan(queries: ["Budget"]))
        llm.answerChunks.set(["Partial"])
        llm.failsStream.set(true)
        let model = AssistantModel(engine: .init(library: world.library, index: world.app.searchIndex,
            voiceprints: world.app.voiceprints), build: { .ready(llm) })
        model.send("Question")
        #expect(await eventually { !model.isRunning })
        #expect(model.turns.last?.answer.text == "Partial")
        #expect(model.turns.last?.steps.first?.state == .done)
        #expect(model.turns.last?.steps.first { $0.kind == .search }?.state == .done)
        #expect(model.turns.last?.steps.first { $0.kind == .read }?.state == .done)
        #expect(model.turns.last?.steps.last?.kind == .answer)
        guard case .failed = model.turns.last?.steps.last?.state else { Issue.record("Missing failed answer activity"); return }
    }

    @Test func paletteHandoffStopsCurrentTurnAndSendsImmediately() async throws {
        let world = try World()
        let llm = FakeLLM()
        llm.planJSON.set(plan(queries: [], lookup: false))
        llm.answerChunks.set(["First partial"])
        llm.lateAfterCancellation.set(["Obsolete answer"])
        llm.holdsStream.set(true)
        let model = AssistantModel(engine: .init(library: world.library, index: world.app.searchIndex,
            voiceprints: world.app.voiceprints), build: { .ready(llm) })
        model.send("First")
        #expect(await eventually { model.turns.last?.answer.text == "First partial" })
        llm.holdsStream.set(false)
        llm.answerChunks.set(["Second answer"])
        model.handoff("Second")
        #expect(model.turns.count == 2)
        #expect(model.turns.first?.state == .stopped)
        #expect(model.turns.first?.answer.text == "First partial")
        #expect(model.turns.last?.question == "Second")
        #expect(await eventually { model.turns.last?.state == .finished })
        #expect(model.turns.last?.answer.text == "Second answer")
        #expect(await eventually { llm.streamCancelled.get })
        #expect(model.turns.first?.answer.text == "First partial")
        #expect(model.turns.last?.answer.text == "Second answer")
    }

    @Test func reversingInterruptedReducedMotionRestoresVisibleLayout() {
        let layout = AssistantLayoutState()
        let entering = layout.begin(active: true, reduced: true)
        #expect(entering && !layout.visible && !layout.active)
        let reversingBeforeApply = layout.begin(active: false, reduced: true)
        #expect(!reversingBeforeApply)
        #expect(layout.visible && !layout.active && !layout.canvasShown)
        _ = layout.begin(active: true, reduced: true)
        layout.apply(active: true, reduced: true)
        #expect(layout.visible && layout.active && layout.canvasShown)
        _ = layout.begin(active: false, reduced: true)
        #expect(!layout.visible)
        _ = layout.begin(active: true, reduced: true)
        #expect(layout.visible && layout.active && layout.canvasShown)
        _ = layout.begin(active: false, reduced: false)
        layout.apply(active: false, reduced: false)
        layout.revealCanvas()
        #expect(layout.visible && !layout.active && !layout.canvasShown)
    }

    @Test func cancelledLayoutTasksCannotOverwriteTheReversedLayout() async throws {
        let layout = AssistantLayoutState()
        let entry = Task { await layout.transition(active: true, reduced: true) }
        #expect(await eventually { !layout.visible })
        entry.cancel()
        await layout.transition(active: false, reduced: true)
        await entry.value
        try await Task.sleep(for: .milliseconds(150))
        #expect(layout.visible && !layout.active && !layout.canvasShown)
        await layout.transition(active: true, reduced: true)
        let exit = Task { await layout.transition(active: false, reduced: true) }
        #expect(await eventually { !layout.visible })
        exit.cancel()
        await layout.transition(active: true, reduced: true)
        await exit.value
        try await Task.sleep(for: .milliseconds(150))
        #expect(layout.visible && layout.active && layout.canvasShown)
    }

    @Test func contextRestoresMentionedPersonFromOriginalCleanedText() async throws {
        let world = try World()
        var meeting = try await world.recordedMeeting(title: "Assignment")
        let person = try await world.app.voiceprints.addPerson(name: "Alex")
        #expect(meeting.speakers.count >= 2)
        meeting.speakers[1].person = person
        let utterance = try #require(meeting.utterances.first)
        meeting.outputs.summary = nil
        meeting.outputs.cleaned = CleanedTranscript(paragraphs: [
            .init(speaker: utterance.speaker, text: "請 \(SpeakerMention.token(meeting.speakers[1].id)) 完成報價指派", sources: [utterance.id]),
            .init(speaker: utterance.speaker, text: "報價指派完成後交由另一位窗口複核", sources: [utterance.id]),
        ])
        try await world.library.save(meeting)
        try await world.app.searchIndex.rebuild(from: [meeting])
        let hits = try await world.app.searchIndex.search(.init(text: "報價指派"))
        #expect(hits.first?.hits.first?.snippet.contains("Alex") == false)
        let llm = FakeLLM()
        llm.planJSON.set(plan(queries: ["報價指派"]))
        let engine = AssistantEngine(library: world.library, index: world.app.searchIndex, voiceprints: world.app.voiceprints)
        for await _ in engine.events(question: "誰負責？", previous: [], provider: llm) {}
        #expect(llm.answerInputs.get.first?.contains("請 Alex 完成報價指派") == true)
        #expect(llm.answerInputs.get.first?.contains("報價指派完成後交由另一位窗口複核") == true)
        #expect(llm.answerInputs.get.first?.contains("{{speaker:") == false)
    }

    @Test func markdownBatchesRailAndScroll() async throws {
        let known: Set<String> = ["m1", "m1.u2"]
        let document = AssistantMarkdown.parse("**Bold**\n- item [m1.u2] [m1] [m1.u2] [m99] [m", known: known)
        #expect(document.citationIDs == ["m1.u2", "m1"])
        #expect(document.plainText == "Bold\n• item 1 2 1  ")
        #expect(document.runs.prefix(4).allSatisfy { $0.bold })
        #expect(AssistantMarkdown.parse("**unfinished*", known: []).plainText == "unfinished")
        #expect(AssistantMarkdown.parse("-", known: []).plainText.isEmpty)
        var batcher = AssistantBatcher()
        let now = Date()
        batcher.append("你"); batcher.append("好")
        let firstFlush = batcher.flush(at: now)
        #expect(firstFlush)
        batcher.append("世界")
        let earlyFlush = batcher.flush(at: now.addingTimeInterval(0.02))
        #expect(!earlyFlush)
        let laterFlush = batcher.flush(at: now.addingTimeInterval(0.06))
        #expect(laterFlush)
        #expect(batcher.text == "你好世界")
        #expect(batcher.batches.map(\.endOffset) == [2, 4])
        var scroll = AssistantFollowScroll()
        scroll.userScrolled(bottomDistance: 100)
        #expect(!scroll.follows)
        scroll.userScrolled(bottomDistance: 10)
        #expect(scroll.follows)
        let world = try World()
        let first = try await world.recordedMeeting(title: "First")
        _ = try await world.recordedMeeting(title: "Second")
        await world.app.meetings.reload()
        let rows = world.app.meetings.rows
        #expect(AssistantRail.ordered(rows, cited: [first.id]).first?.id == first.id)
        #expect(AssistantRail.ordered(rows, cited: []).map(\.id) == rows.map(\.id))
    }

    private func plan(queries: [String], people: [String] = [], from: String? = nil, to: String? = nil, lookup: Bool = true) -> String {
        let object: [String: Any] = ["reasoning": "Look up meetings", "queries": queries, "people": people,
            "dateFrom": from as Any? ?? NSNull(), "dateTo": to as Any? ?? NSNull(), "needsMeetings": lookup]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
