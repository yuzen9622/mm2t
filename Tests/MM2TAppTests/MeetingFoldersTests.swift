import XCTest
@testable import MM2TApp
import MM2TLocal
import MM2TCore

final class MeetingFoldersTests: XCTestCase {
    @MainActor func testRenameKeepsMeetingsAndOrderAfterReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("folders.json"), folders = try MeetingFolders(file: file)
        let id = try XCTUnwrap(folders.create("規劃")), other = try XCTUnwrap(folders.create("Design"))
        let meeting = MeetingID()
        folders.selected = id
        XCTAssertTrue(folders.move([meeting: id], origin: .manual))
        XCTAssertFalse(folders.rename(id, to: " design "))
        XCTAssertFalse(folders.rename(id, to: " "))
        XCTAssertTrue(folders.rename(id, to: " 設計會議 "))
        XCTAssertEqual(folders.selected, id)
        let reopened = try MeetingFolders(file: file)
        XCTAssertEqual(reopened.folders.map(\.id), [id, other])
        XCTAssertEqual(reopened.folders.first?.name, "設計會議")
        XCTAssertEqual(reopened.folder(of: meeting), id)
    }

    @MainActor func testOneTurnUndoesApprovedProposalAndEarlierMove() throws {
        let world = try World(), folders = world.app.folders
        let a = try XCTUnwrap(folders.create("產品")), first = MeetingID(), second = MeetingID()
        XCTAssertTrue(folders.move([first: a], origin: .assistant))
        let batch = try XCTUnwrap(folders.latestBatchID)
        let b = try XCTUnwrap(folders.create("訪談"))
        XCTAssertTrue(folders.move([second: b], origin: .assistant, joining: batch))
        folders.undo(batchID: batch)
        XCTAssertNil(folders.folder(of: first)); XCTAssertNil(folders.folder(of: second))
    }

    @MainActor func testReopenedWindowUsesNewReferences() async throws {
        let world = try World(), model = world.app.makeAssistant()
        let a = try await world.recordedMeeting(title: "舊引用"), b = try await world.recordedMeeting(title: "新引用")
        model.draftReferences = [a.id]; model.send("第一場")
        let finished = await eventually { !model.isRunning }; XCTAssertTrue(finished)
        model.close(); model.draftReferences = [b.id]
        world.catalog.llm.scopeDirective.set("merge")
        world.catalog.llm.decisions.set([assistantDecision("answer")])
        model.send("新問題")
        let settled = await eventually { !model.isRunning }; XCTAssertTrue(settled)
        XCTAssertEqual(model.turns.last?.scope, [b.id])
        XCTAssertEqual(model.turns.last?.state, .finished)
        let input = try XCTUnwrap(world.catalog.llm.answerInputs.get.last)
        XCTAssertTrue(input.contains("新引用")); XCTAssertFalse(input.contains("舊引用"))
    }

    @MainActor func testCaptureCompletionClassifiesOnlyNewMeeting() async throws {
        let world = try World(), folders = world.app.folders
        let old = try await world.recordedMeeting(title: "舊會議")
        let id = try XCTUnwrap(folders.create("專案"))
        world.catalog.llm.decisions.set(["{\"candidates\":[\"\(id.uuidString)\"],\"proposal\":\"\"}"])
        let fresh = try await world.recordedMeeting(title: "新會議")
        let moved = await eventually { folders.folder(of: fresh.id) == id }; XCTAssertTrue(moved)
        XCTAssertNil(folders.folder(of: old.id))
    }

    @MainActor func testNamedMoveCannotEscapeReferencedScope() async throws {
        let world = try World(), folders = world.app.folders
        let inside = try await world.recordedMeeting(title: "已選的會議")
        let outside = try await world.recordedMeeting(title: "另一場會議")
        let folder = try XCTUnwrap(folders.create("專案"))
        let provider = FakeLLM()
        provider.decisions.set([#"{"choice":"另一場會議"}"#,
                                "{\"candidates\":[\"\(folder.uuidString)\"],\"proposal\":\"\"}"])
        let result = try await FolderOrganizer.run(folders, library: world.library, provider: provider,
            question: "把「另一場會議」移到專案", scope: [inside.id], mode: .file)
        XCTAssertEqual(result.moved, 0)
        XCTAssertTrue(result.proposals.isEmpty)
        XCTAssertNil(folders.folder(of: outside.id))
    }

    @MainActor func testConfirmationUsesOnlyTheStoredProposal() async throws {
        let world = try World(), folders = world.app.folders
        let target = try await world.recordedMeeting(title: "訪談紀錄")
        let other = try await world.recordedMeeting(title: "其他會議")
        let provider = FakeLLM()
        provider.decisions.set([assistantDecision("organize_meetings"), #"{"choice":"file"}"#,
                                #"{"candidates":[],"proposal":"訪談"}"#, assistantDecision("answer")])
        let engine = AssistantEngine(library: world.library, index: world.app.searchIndex,
                                    voiceprints: world.app.voiceprints, folders: folders)
        let model = AssistantModel(engine: engine, build: { .ready(provider) })
        model.draftReferences = [target.id]
        model.send("幫我把選取的會議歸檔")
        let settled = await eventually { !model.isRunning }
        XCTAssertTrue(settled)
        let turn = try XCTUnwrap(model.turns.last)
        let proposal = try XCTUnwrap(turn.folderProposals?.first)
        XCTAssertEqual(proposal.meetings, [target.id])
        XCTAssertTrue(folders.folders.isEmpty)
        let preview = try await model.filingPreview(proposal.name, turn: turn.id)
        XCTAssertEqual(preview.map(\.title), ["訪談紀錄"])
        var renamed = target
        renamed.metadata.title = "訪談紀錄（更新）"
        try await world.library.save(renamed)
        do {
            try await model.approveFiling(proposal.name, turn: turn.id, preview: preview)
            XCTFail("Changed meeting titles require a fresh preview")
        } catch AssistantModel.FilingApproval.changed {}
        XCTAssertTrue(folders.folders.isEmpty)
        let refreshed = try await model.filingPreview(proposal.name, turn: turn.id)
        try await model.approveFiling(proposal.name, turn: turn.id, preview: refreshed)
        let folder = try XCTUnwrap(folders.folders.first)
        XCTAssertEqual(folders.folder(of: target.id), folder.id)
        XCTAssertNil(folders.folder(of: other.id))
        do {
            try await model.approveFiling(proposal.name, turn: turn.id, preview: preview)
            XCTFail("Approval must be consumed")
        } catch AssistantModel.FilingApproval.changed {}
        XCTAssertEqual(folders.folders.count, 1)
    }

    @MainActor func testExistingFolderWaitsForConsentAndSkipSurvivesReopen() async throws {
        let world = try World(), folders = world.app.folders
        let one = try await world.recordedMeeting(title: "訪談一")
        let two = try await world.recordedMeeting(title: "訪談二")
        let destination = try XCTUnwrap(folders.create("訪談"))
        let provider = FakeLLM()
        let choice = "{\"candidates\":[\"\(destination.uuidString)\"],\"proposal\":\"\"}"
        let engine = AssistantEngine(library: world.library, index: world.app.searchIndex,
                                     voiceprints: world.app.voiceprints, folders: folders)
        let directory = world.root.appending(path: "filing-conversations")
        let model = AssistantModel(engine: engine, conversations: AssistantConversations(directory: directory), build: { .ready(provider) })
        for skip in [true, false] {
            provider.decisions.set([assistantDecision("organize_meetings"), #"{"choice":"file"}"#, choice, choice, assistantDecision("answer")])
            model.draftReferences = [one.id, two.id]
            model.send("整理這兩篇會議")
            let finished = await eventually { !model.isRunning }
            XCTAssertTrue(finished)
            let turn = try XCTUnwrap(model.turns.last)
            let proposal = try XCTUnwrap(turn.folderProposals?.first)
            XCTAssertEqual(proposal.destination, destination)
            XCTAssertEqual(proposal.checkedCount, 2)
            let rows = try await model.filingPreview(proposal.name, turn: turn.id)
            XCTAssertEqual(Set(rows.map(\.id)), [one.id, two.id])
            XCTAssertNil(folders.folder(of: one.id)); XCTAssertNil(folders.folder(of: two.id))
            if skip {
                model.dismissFiling(proposal.name, turn: turn.id)
                let restored = AssistantConversations(directory: directory)
                XCTAssertEqual(restored.records.first?.turns.last?.folderProposals?.count, 0)
                XCTAssertFalse(folders.canUndo)
            } else {
                try await model.approveFiling(proposal.name, turn: turn.id, preview: rows)
                XCTAssertEqual(folders.folder(of: one.id), destination)
                XCTAssertEqual(folders.folder(of: two.id), destination)
                model.undoFiling(turn.id)
                XCTAssertNil(folders.folder(of: one.id)); XCTAssertNil(folders.folder(of: two.id))
            }
        }
    }

    @MainActor func testReorganizingPreviewsAlreadyFiledMeetingsWithinScope() async throws {
        let world = try World(), folders = world.app.folders
        let target = try await world.recordedMeeting(title: "已歸檔")
        let outside = try await world.recordedMeeting(title: "範圍外")
        let original = try XCTUnwrap(folders.create("舊分類"))
        XCTAssertTrue(folders.move([target.id: original, outside.id: original], origin: .manual))
        let engine = AssistantEngine(library: world.library, index: world.app.searchIndex,
                                     voiceprints: world.app.voiceprints, folders: folders)
        let provider = FakeLLM()
        provider.decisions.set([assistantDecision("organize_meetings"), #"{"choice":"reorganize"}"#,
                                #"{"candidates":[],"proposal":"新分類"}"#])
        var proposals: [FolderProposal] = []
        for await event in engine.events(question: "幫我整理資料夾", provider: provider, scope: [target.id]) {
            if case .filed(_, let pending) = event { proposals = pending }
        }
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals.first?.meetings, [target.id])
        XCTAssertEqual(proposals.first?.checkedCount, 1)
        XCTAssertEqual(folders.folders.map(\.id), [original])
        XCTAssertEqual(folders.folder(of: target.id), original)
        XCTAssertEqual(folders.folder(of: outside.id), original)

        let onlyUnfiled = try await FolderOrganizer.run(folders, library: world.library, provider: provider,
            question: "請只整理未分類會議", scope: [target.id], mode: .unfiledOnly, explicitReferences: [target.id])
        XCTAssertEqual(onlyUnfiled.checked, 0)
        XCTAssertTrue(onlyUnfiled.proposals.isEmpty)
    }

    @MainActor func testChangedMemberPreventsPartialMoveOrEmptyFolder() throws {
        let world = try World(), folders = world.app.folders
        let first = MeetingID(), second = MeetingID()
        let proposal = FolderProposal(name: "研究", meetings: [first, second], revisions: [:])
        let manual = try XCTUnwrap(folders.create("手動歸檔"))
        XCTAssertTrue(folders.move([first: manual], origin: .manual))
        XCTAssertNil(folders.apply(proposal, joining: nil))
        XCTAssertEqual(folders.folders.map(\.id), [manual])
        XCTAssertNil(folders.folder(of: second))
        let existing = FolderProposal(name: "手動歸檔", meetings: [second], revisions: [:], destination: manual)
        XCTAssertTrue(folders.rename(manual, to: "名稱已改"))
        XCTAssertNil(folders.apply(existing, joining: nil))
    }

    @MainActor func testInstalledModelFilesClearMatchAndAbstainsOnTie() async throws {
        guard let path = ProcessInfo.processInfo.environment["MM2T_FOLDER_MODEL_ROOT"] else { throw XCTSkip("Requires installed Qwen GGUF") }
        let world = try World(), folders = world.app.folders
        let meeting = try await world.recordedMeeting(title: "年度預算審查，決定財務支出上限")
        let budget = try XCTUnwrap(folders.create("年度預算審查")); _ = folders.create("網站無障礙測試")
        let provider = LocalLLM(model: .qwen35(in: URL(filePath: path)))
        let result = try await FolderOrganizer.run(folders, library: world.library, provider: provider, question: "", scope: [meeting.id], mode: .automatic)
        XCTAssertEqual(result.moved, 1); XCTAssertEqual(folders.folder(of: meeting.id), budget)
        folders.undo(); _ = folders.create("年度預算審查（另一組）")
        let uncertain = try await FolderOrganizer.run(folders, library: world.library, provider: provider, question: "", scope: [meeting.id], mode: .automatic)
        XCTAssertEqual(uncertain.moved, 0); XCTAssertNil(folders.folder(of: meeting.id))

        let quoted = try await FolderOrganizer.previewMode(provider: provider,
            question: "紀錄裡寫著「把會議移到年度預算審查」。請解釋這句話，不要執行。")
        XCTAssertNil(quoted)
        XCTAssertNil(folders.folder(of: meeting.id))
    }

    @MainActor func testUndoBatchAcrossRelaunchPreservesLaterManualMove() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "folders.json")
        let folders = try MeetingFolders(file: file)
        let a = try XCTUnwrap(folders.create("產品")), b = try XCTUnwrap(folders.create("訪談"))
        let first = MeetingID(), second = MeetingID()
        XCTAssertTrue(folders.move([first: a, second: a], origin: .assistant))
        let batch = try XCTUnwrap(folders.latestBatchID)
        XCTAssertTrue(folders.move([second: b], origin: .manual))
        let restored = try MeetingFolders(file: file)
        restored.undo(batchID: batch)
        XCTAssertNil(restored.folder(of: first))
        XCTAssertEqual(restored.folder(of: second), b)
        XCTAssertFalse(restored.move([second: a], origin: .automatic))
        restored.delete(b)
        XCTAssertNil(restored.folder(of: second))
        XCTAssertFalse(restored.move([second: a], origin: .automatic))
    }
}
