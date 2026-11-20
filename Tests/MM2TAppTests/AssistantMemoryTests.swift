import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TApp

@MainActor @Suite struct AssistantMemoryTests {
    @Test func conversationsRestoreAndHaveOneWriter() async throws {
        let world = try World()
        let engine = AssistantEngine(library: world.library, index: world.app.searchIndex, voiceprints: world.app.voiceprints)
        let directory = world.root.appending(path: "conversations")
        let store = AssistantConversations(directory: directory)
        let llm = FakeLLM(); llm.decisions.set([assistantDecision("answer")])
        let model = AssistantModel(engine: engine, conversations: store, build: { .ready(llm) })
        model.send("第一個問題")
        #expect(await eventually { !model.isRunning })
        let id = model.conversationID
        let owner = UUID()
        #expect(throws: AssistantQueryError.self) { try store.open(id, owner: owner) }
        model.close()
        let restored = AssistantModel(engine: engine, conversations: AssistantConversations(directory: directory), build: { .ready(llm) })
        #expect(restored.conversationID == id)
        #expect(restored.turns.first?.question == "第一個問題")
        #expect(restored.turns.first?.answer.text == model.turns.first?.answer.text)
        restored.send("第二個問題")
        #expect(await eventually { !restored.isRunning })
        #expect(llm.generationInputs.get.last?.contains("第一個問題") == true)
        restored.newConversation()
        #expect(restored.turns.isEmpty)
        #expect(restored.conversationID != id)
    }

    @Test func preferencesRequireConfirmationAndDeletionInvalidatesHistory() async throws {
        let world = try World()
        let llm = FakeLLM()
        llm.decisions.set([assistantDecision("answer")])
        llm.memoryJSON.set(#"{"preference":"使用特別偏好ABC格式"}"#)
        let model = AssistantModel(engine: .init(library: world.library, index: world.app.searchIndex, voiceprints: world.app.voiceprints),
            conversations: world.app.assistantConversations, preferences: world.app.assistantPreferences, build: { .ready(llm) })
        model.send("請記住使用特別偏好ABC格式")
        #expect(await eventually { model.turns.first?.memoryProposal != nil && !model.isRunning })
        #expect(world.app.assistantPreferences.items.isEmpty)
        let turnID = try #require(model.turns.first?.id)
        model.confirmPreference(turn: turnID, text: "使用特別偏好ABC格式")
        #expect(world.app.assistantPreferences.items.count == 1)
        let preferenceID = try #require(world.app.assistantPreferences.items.first?.id)
        llm.memoryJSON.set(#"{"preference":null}"#)
        model.send("你好")
        #expect(await eventually { !model.isRunning })
        #expect(llm.answerInputs.get.last?.contains("使用特別偏好ABC格式") == true)
        try world.app.assistantPreferences.delete(preferenceID)
        model.send("再次你好")
        #expect(await eventually { !model.isRunning })
        #expect(llm.generationInputs.get.last?.contains("特別偏好ABC") == false)
        #expect(llm.answerInputs.get.last?.contains("特別偏好ABC") == false)
        let reloaded = AssistantPreferences(file: world.app.paths.assistantPreferences)
        #expect(reloaded.items.isEmpty)
    }

    @Test func reopeningSameConversationKeepsLeaseAndEmptyMemoryRevision() async throws {
        let world = try World()
        let model = world.app.makeAssistant()
        world.catalog.llm.decisions.set([assistantDecision("answer")])
        model.send("保存這個問題")
        #expect(await eventually { !model.isRunning })
        let id = model.conversationID
        model.openConversation(id)
        #expect(model.save())
        #expect(throws: AssistantQueryError.self) { try world.app.assistantConversations.open(id, owner: UUID()) }
        model.close()
        model.send("接續同一段對話")
        #expect(await eventually { !model.isRunning })
        #expect(model.storageError == nil)
        #expect(model.conversationID == id)
        let restoredPreferences = AssistantPreferences(file: world.app.paths.assistantPreferences)
        #expect(restoredPreferences.revision == world.app.assistantPreferences.revision)
        let saved = try #require(world.app.assistantConversations.records.first)
        #expect(saved.history(memoryRevision: restoredPreferences.revision).contains("Answer"))
    }

    @Test func previousCitationsSurviveAFormattingFollowup() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        try await world.app.searchIndex.rebuild(from: [meeting])
        let llm = FakeLLM()
        let model = AssistantModel(engine: .init(library: world.library, index: world.app.searchIndex, voiceprints: world.app.voiceprints), build: { .ready(llm) })
        model.send("找預算")
        #expect(await eventually { !model.isRunning })
        let first = model.turns[0].citedSources
        #expect(!first.isEmpty)
        llm.decisions.set([assistantDecision("answer")])
        model.send("把剛才的答案縮短")
        #expect(await eventually { !model.isRunning })
        #expect(model.turns[1].citedSources.map(\.id) == first.map(\.id))
        #expect(model.turns[1].citedSources.map(\.meeting) == first.map(\.meeting))
    }

    @Test func unclassifiedPreferenceTextIsNotReinjectedAfterRevisionChange() async throws {
        let world = try World()
        let model = world.app.makeAssistant()
        world.catalog.llm.decisions.set([assistantDecision("answer")])
        model.send("偏好特殊格式XYZ，但這次沒有成功建立提案")
        #expect(await eventually { !model.isRunning })
        try world.app.assistantPreferences.setEnabled(false)
        model.send("另一個問題")
        #expect(await eventually { !model.isRunning })
        #expect(world.catalog.llm.generationInputs.get.last?.contains("特殊格式XYZ") == false)
    }

    @Test func editingDisabledPreferenceDoesNotEnableIt() throws {
        let file = try temporaryDirectory().appending(path: "preferences.json")
        let store = AssistantPreferences(file: file)
        try store.put(text: "原偏好", enabled: false)
        let id = try #require(store.items.first?.id)
        try store.put(id: id, text: "修正偏好")
        #expect(store.items.first?.enabled == false)
        #expect(store.context(for: "修正偏好").isEmpty)
    }

    @Test func closingAfterSaveFailureKeepsUnsavedTurns() async throws {
        let world = try World()
        let directory = world.root.appending(path: "cannot-write")
        try Data("not a directory".utf8).write(to: directory)
        let store = AssistantConversations(directory: directory)
        let llm = FakeLLM(); llm.decisions.set([assistantDecision("answer")])
        let model = AssistantModel(engine: .init(library: world.library, index: world.app.searchIndex, voiceprints: world.app.voiceprints),
            conversations: store, build: { .ready(llm) })
        model.send("不能遺失的問題")
        #expect(await eventually { !model.isRunning })
        model.close()
        #expect(model.storageError != nil)
        #expect(model.turns.first?.question == "不能遺失的問題")
        model.send("第二個問題")
        #expect(await eventually { !model.isRunning })
        #expect(model.turns.map(\.question) == ["不能遺失的問題", "第二個問題"])
    }

    @Test func corruptFilesArePreserved() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "preferences.json")
        let bytes = Data("not json".utf8)
        try bytes.write(to: file)
        let preferences = AssistantPreferences(file: file)
        #expect(preferences.error != nil)
        #expect(throws: AssistantQueryError.self) { try preferences.put(text: "不要覆寫損壞檔案") }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func repeatCallsDoNotLoopAndObservationsReachPlanner() async throws {
        let world = try World()
        let llm = FakeLLM()
        llm.decisions.set([assistantDecision("search_meetings", query: "nothing"),
                           assistantDecision("search_meetings", query: "nothing"), assistantDecision("search_meetings", query: "nothing")])
        let engine = AssistantEngine(library: world.library, index: world.app.searchIndex, voiceprints: world.app.voiceprints)
        var tools = 0
        for await event in engine.events(question: "找資料", provider: llm) {
            if case .toolStarted = event { tools += 1 }
        }
        #expect(tools == 1)
        #expect(llm.generationInputs.get.count == 2)
        #expect(llm.generationInputs.get.last?.contains("SEARCH: 0 matching meetings") == true)
        #expect(llm.answerInputs.get.last?.contains("Duplicate tool call refused") == true)
    }
}
