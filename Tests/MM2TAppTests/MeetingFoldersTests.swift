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

    @MainActor func testInstalledModelFilesClearMatchAndAbstainsOnTie() async throws {
        guard let path = ProcessInfo.processInfo.environment["MM2T_FOLDER_MODEL_ROOT"] else { throw XCTSkip("Requires installed Qwen GGUF") }
        let world = try World(), folders = world.app.folders
        let meeting = try await world.recordedMeeting(title: "年度預算審查，決定財務支出上限")
        let budget = try XCTUnwrap(folders.create("年度預算審查")); _ = folders.create("網站無障礙測試")
        let provider = LocalLLM(model: .qwen35(in: URL(filePath: path)))
        let result = try await FolderOrganizer.run(folders, library: world.library, provider: provider, question: "", scope: [meeting.id], automatic: true)
        XCTAssertEqual(result.moved, 1); XCTAssertEqual(folders.folder(of: meeting.id), budget)
        folders.undo(); _ = folders.create("年度預算審查（另一組）")
        let uncertain = try await FolderOrganizer.run(folders, library: world.library, provider: provider, question: "", scope: [meeting.id], automatic: true)
        XCTAssertEqual(uncertain.moved, 0); XCTAssertNil(folders.folder(of: meeting.id))
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
