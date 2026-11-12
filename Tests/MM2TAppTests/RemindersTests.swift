import Foundation
import Testing
@testable import MM2TApp

/// Reminders as a dictionary the test can edit the way the Reminders app would.
final class FakeReminders: ReminderStore, @unchecked Sendable {
    struct Entry { var draft: ReminderDraft; var list: String; var completed: Bool }
    private let state = Box<(access: RemindersAccess, entries: [String: Entry], next: Int, willGrant: Bool)>(
        (.notDetermined, [:], 0, true))

    init(access: RemindersAccess = .granted, willGrant: Bool = true) {
        state.update { $0.access = access; $0.willGrant = willGrant }
    }

    var access: RemindersAccess { state.get.access }
    var entries: [String: Entry] { state.get.entries }

    func requestAccess() async -> Bool {
        state.update { if $0.access == .notDetermined { $0.access = $0.willGrant ? .granted : .denied } }
        return access == .granted
    }

    func create(_ draft: ReminderDraft, inList list: String) async throws -> String {
        guard access == .granted else { throw ReminderError.denied }
        var id = ""
        state.update {
            $0.next += 1
            id = "R\($0.next)"
            $0.entries[id] = Entry(draft: draft, list: list, completed: draft.isCompleted)
        }
        return id
    }

    func completion(of ids: [String]) async -> [String: Bool] {
        let entries = state.get.entries
        return ids.reduce(into: [:]) { $0[$1] = entries[$1]?.completed }
    }

    func setCompleted(_ id: String, _ completed: Bool) async throws {
        guard entries[id] != nil else { throw ReminderError.notFound }
        state.update { $0.entries[id]?.completed = completed }
    }

    var changes: AsyncStream<Void> { AsyncStream { $0.finish() } }

    // What the user does in the Reminders app.
    func complete(_ id: String, _ completed: Bool) { state.update { $0.entries[id]?.completed = completed } }
    func delete(_ id: String) { state.update { $0.entries[id] = nil } }
}

@MainActor
struct RemindersTests {
    let directory: URL
    let status: TodoStatus
    let store: FakeReminders
    let sync: RemindersSync

    init(access: RemindersAccess = .granted, willGrant: Bool = true) throws {
        directory = try temporaryDirectory()
        status = TodoStatus(file: directory.appending(path: "todos.json"))
        store = FakeReminders(access: access, willGrant: willGrant)
        sync = RemindersSync(store: store, status: status, file: directory.appending(path: "reminders.json"))
    }

    private func draft(_ id: String, _ title: String = "整理報價") -> ReminderDraft {
        ReminderDraft(todoID: id, title: title, notes: "週會, Nov 12")
    }

    @Test func addCreatesAReminderInTheListAndLinksIt() async throws {
        await sync.add([draft("m#0")])
        let id = try #require(sync.links["m#0"])
        let entry = try #require(store.entries[id])
        #expect(entry.list == "mm2t")
        #expect(entry.draft.title == "整理報價" && entry.draft.notes == "週會, Nov 12")
        #expect(sync.isLinked("m#0"))
    }

    @Test func addingAgainDoesNotDuplicate() async {
        await sync.add([draft("m#0"), draft("m#1", "寄信")])
        await sync.add([draft("m#0"), draft("m#1", "寄信")])
        #expect(store.entries.count == 2)
    }

    @Test func linksSurviveARestart() async throws {
        await sync.add([draft("m#0")])
        let again = RemindersSync(store: store, status: status, file: directory.appending(path: "reminders.json"))
        #expect(again.links == sync.links)
        await again.add([draft("m#0")])
        #expect(store.entries.count == 1)
    }

    @Test func aDoneTodoIsCreatedCompleted() async throws {
        status.toggle("m#0")
        await sync.add([draft("m#0")])
        #expect(try #require(store.entries.values.first).completed)
    }

    @Test func checkingATodoCompletesItsReminder() async throws {
        await sync.add([draft("m#0")])
        let id = try #require(sync.links["m#0"])
        status.toggle("m#0")
        await sync.reconcile()
        #expect(store.entries[id]?.completed == true)
        #expect(status.isDone("m#0"), "the read that follows the push does not undo it")
        status.toggle("m#0")
        await sync.reconcile()
        #expect(store.entries[id]?.completed == false)
    }

    @Test func completingInRemindersChecksTheTodo() async throws {
        await sync.add([draft("m#0")])
        let id = try #require(sync.links["m#0"])
        store.complete(id, true)
        await sync.reconcile()
        #expect(status.isDone("m#0"))
        store.complete(id, false)
        await sync.reconcile()
        #expect(!status.isDone("m#0"))
    }

    @Test func aDeletedReminderUnlinksAndKeepsTheTodo() async throws {
        await sync.add([draft("m#0")])
        status.toggle("m#0")
        let id = try #require(sync.links["m#0"])
        store.delete(id)
        await sync.reconcile()
        #expect(!sync.isLinked("m#0"))
        #expect(status.isDone("m#0"))
        status.toggle("m#0")
        await sync.reconcile()
        #expect(!status.isDone("m#0"), "an unlinked todo no longer follows Reminders")
        await sync.add([draft("m#0")])
        #expect(sync.isLinked("m#0"), "it can be added again")
    }

    @Test func togglingAfterTheReminderWasDeletedUnlinks() async throws {
        await sync.add([draft("m#0")])
        store.delete(try #require(sync.links["m#0"]))
        status.toggle("m#0")
        await sync.reconcile()
        #expect(!sync.isLinked("m#0") && status.isDone("m#0"))
    }

    @Test func addAsksForAccessFirstAndStopsWhenDenied() async {
        let denied = try! RemindersTests(access: .notDetermined, willGrant: false)
        await denied.sync.add([denied.draft("m#0")])
        #expect(denied.sync.access == .denied)
        #expect(denied.sync.links.isEmpty && denied.store.entries.isEmpty)

        let granted = try! RemindersTests(access: .notDetermined)
        await granted.sync.add([granted.draft("m#0")])
        #expect(granted.sync.access == .granted && granted.sync.isLinked("m#0"))
    }

    @Test func noAccessLeavesLinksAlone() async throws {
        await sync.add([draft("m#0")])
        let revoked = FakeReminders(access: .denied)
        let again = RemindersSync(store: revoked, status: status, file: directory.appending(path: "reminders.json"))
        await again.reconcile()
        #expect(again.isLinked("m#0") && again.access == .denied)
    }
}
