import Foundation
import EventKit
import Testing
@testable import MM2TCore
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

    var failDeadlineWrites = false

    func fillMissingDeadline(_ id: String, expectedTitle: String, due: ActionDeadline) async throws {
        guard access == .granted else { throw ReminderError.denied }
        if failDeadlineWrites { throw ReminderError.denied }
        guard let entry = entries[id] else { throw ReminderError.notFound }
        guard entry.draft.title == expectedTitle, entry.draft.due == nil else { return }
        let draft = entry.draft
        state.update {
            $0.entries[id]?.draft = ReminderDraft(todoID: draft.todoID, title: draft.title, notes: draft.notes,
                due: due, isCompleted: draft.isCompleted)
        }
    }

    var changes: AsyncStream<Void> { AsyncStream { $0.finish() } }

    // What the user does in the Reminders app.
    func complete(_ id: String, _ completed: Bool) { state.update { $0.entries[id]?.completed = completed } }
    func delete(_ id: String) { state.update { $0.entries[id] = nil } }
    func edit(_ id: String, title: String? = nil, due: ActionDeadline? = nil) {
        state.update {
            guard let draft = $0.entries[id]?.draft else { return }
            $0.entries[id]?.draft = ReminderDraft(todoID: draft.todoID, title: title ?? draft.title, notes: draft.notes,
                due: due, isCompleted: draft.isCompleted)
        }
    }
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

    @Test func addingPreservesDueTimeAndAllDayPrecision() async throws {
        let timed = try #require(ActionDeadline.parse("2026-11-15T15:30:00+08:00", timeZoneIdentifier: "Asia/Taipei"))
        let day = try #require(ActionDeadline.parse("2026-11-16", timeZoneIdentifier: "Asia/Taipei"))
        await sync.add([
            ReminderDraft(todoID: "m#0", title: "寄出", notes: "", due: timed),
            ReminderDraft(todoID: "m#1", title: "確認", notes: "", due: day),
        ])
        #expect(store.entries[try #require(sync.links["m#0"])]?.draft.due == timed)
        #expect(store.entries[try #require(sync.links["m#1"])]?.draft.due == day)
    }

    @Test func eventKitGetsADueTimeAndAlarmOnlyWhenATimeWasSpoken() throws {
        // Unsaved objects exercise the real EventKit mapping without accessing the user's reminders.
        let reminder = EKReminder(eventStore: EKEventStore())
        let timed = try #require(ActionDeadline.parse("2026-11-15T15:30:00+08:00", timeZoneIdentifier: "Asia/Taipei"))
        SystemReminders.applyDeadline(timed, to: reminder)
        #expect(reminder.dueDateComponents?.hour == 15 && reminder.dueDateComponents?.minute == 30)
        #expect(reminder.alarms?.first?.absoluteDate == timed.date)
        let day = try #require(ActionDeadline.parse("2026-11-16", timeZoneIdentifier: "Asia/Taipei"))
        SystemReminders.applyDeadline(day, to: reminder)
        #expect(reminder.dueDateComponents?.day == 16 && reminder.dueDateComponents?.hour == nil)
        #expect(reminder.alarms?.isEmpty != false)
        SystemReminders.applyDeadline(nil, to: reminder)
        #expect(reminder.dueDateComponents == nil && reminder.alarms?.isEmpty != false)
    }

    @Test func existingUndatedRemindersAreRepairedWithoutOverwritingAnEditedDay() async throws {
        let timed = try #require(ActionDeadline.parse("2026-11-15T15:30:00+08:00", timeZoneIdentifier: "Asia/Taipei"))
        let chosenDay = try #require(ActionDeadline.parse("2026-11-18", timeZoneIdentifier: "Asia/Taipei"))
        await sync.add([draft("m#0", "寄出"), ReminderDraft(todoID: "m#1", title: "確認", notes: "", due: chosenDay)])
        await sync.fillMissingDeadlines([
            ReminderDraft(todoID: "m#0", title: "寄出", notes: "", due: timed),
            ReminderDraft(todoID: "m#1", title: "確認", notes: "", due: timed),
            ReminderDraft(todoID: "m#2", title: "未加入", notes: "", due: timed),
        ])
        #expect(store.entries.count == 2)
        #expect(store.entries[try #require(sync.links["m#0"])]?.draft.due == timed)
        #expect(store.entries[try #require(sync.links["m#1"])]?.draft.due == chosenDay)
    }

    @Test func deadlineRepairCanRetryAndDeniedAccessPreservesTheLink() async throws {
        await sync.add([draft("m#0", "寄出")])
        let timed = try #require(ActionDeadline.parse("2026-11-15T15:30:00+08:00", timeZoneIdentifier: "Asia/Taipei"))
        let scheduled = ReminderDraft(todoID: "m#0", title: "寄出", notes: "", due: timed)
        store.failDeadlineWrites = true
        await sync.fillMissingDeadlines([scheduled])
        #expect(sync.failed && sync.isLinked("m#0"))
        store.failDeadlineWrites = false
        await sync.fillMissingDeadlines([scheduled])
        #expect(!sync.failed)
        #expect(store.entries[try #require(sync.links["m#0"])]?.draft.due == timed)
        let denied = RemindersSync(store: FakeReminders(access: .denied), status: status, file: directory.appending(path: "reminders.json"))
        await denied.fillMissingDeadlines([scheduled])
        #expect(denied.isLinked("m#0") && denied.access == .denied)
    }

    @Test func deadlineRepairDoesNotTouchAReminderRenamedByTheUser() async throws {
        await sync.add([draft("m#0", "寄出報價")])
        let reminderID = try #require(sync.links["m#0"])
        store.edit(reminderID, title: "改成下週與客戶確認")
        let due = try #require(ActionDeadline.parse("2026-11-15T15:30:00+08:00", timeZoneIdentifier: "Asia/Taipei"))
        await sync.fillMissingDeadlines([ReminderDraft(todoID: "m#0", title: "寄出報價", notes: "", due: due)])
        #expect(store.entries[reminderID]?.draft.due == nil)
        #expect(store.entries[reminderID]?.draft.title == "改成下週與客戶確認")

        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.title = "使用者改名"
        #expect(!SystemReminders.applyMissingDeadline(due, expectedTitle: "寄出報價", to: reminder))
        #expect(reminder.dueDateComponents == nil && reminder.alarms?.isEmpty != false)
        reminder.title = "寄出報價"
        #expect(SystemReminders.applyMissingDeadline(due, expectedTitle: "寄出報價", to: reminder))
        #expect(reminder.alarms?.first?.absoluteDate == due.date)
    }

    @Test func aRegeneratedSummaryCannotRepairAnUnrelatedReminderAtTheSameIndex() async throws {
        let world = try World()
        var meeting = try await world.recordedMeeting()
        meeting.outputs.summary = Summary(decisions: [], discussionPoints: [], actionItems: [
            .init(text: "寄出報價", owner: nil, sources: []),
            .init(text: "確認設計", owner: nil, sources: []),
        ])
        try await world.library.save(meeting)
        let detail = MeetingDetailModel(id: meeting.id, library: world.library, voiceprints: world.app.voiceprints,
            queue: world.queue, labels: testLabels, playback: nil, todos: status, reminders: sync)
        await detail.load()
        await detail.addToReminders()
        let before = store.entries
        let due = try #require(ActionDeadline.parse("2026-11-15T15:30:00+08:00", timeZoneIdentifier: "Asia/Taipei"))
        // Regeneration changes the order, but the existing links still use meeting#index.
        meeting.outputs.summary = Summary(decisions: [], discussionPoints: [], actionItems: [
            .init(text: "確認設計", owner: nil, sources: [], due: due),
            .init(text: "寄出報價", owner: nil, sources: [], due: due),
        ])
        try await world.library.save(meeting)
        await detail.load()
        #expect(store.entries.count == 2)
        for (id, entry) in before {
            #expect(store.entries[id]?.draft == entry.draft)
        }
    }

    @Test func clearingADateIsRespectedAcrossLoadsAndRestarts() async throws {
        let due = try #require(ActionDeadline.parse("2026-11-15T15:30:00+08:00", timeZoneIdentifier: "Asia/Taipei"))
        let drafts = [ReminderDraft(todoID: "m#0", title: "舊版提醒", notes: "", due: due),
                      ReminderDraft(todoID: "m#1", title: "新版提醒", notes: "", due: due)]
        await sync.add([draft("m#0", "舊版提醒"), drafts[1]])
        await sync.fillMissingDeadlines(drafts)
        for reminderID in sync.links.values { store.edit(reminderID, due: nil) }
        await sync.fillMissingDeadlines(drafts)
        let restarted = RemindersSync(store: store, status: status, file: directory.appending(path: "reminders.json"))
        await restarted.fillMissingDeadlines(drafts)
        #expect(store.entries.values.allSatisfy { $0.draft.due == nil })
        #expect(store.entries.count == 2)
    }

    @Test func anUndatedDraftCanReceiveItsFirstDeadlineLater() async throws {
        await sync.add([draft("m#0", "寄出報價")])
        await sync.fillMissingDeadlines([draft("m#0", "寄出報價")])
        let due = try #require(ActionDeadline.parse("2026-11-15", timeZoneIdentifier: "Asia/Taipei"))
        await sync.fillMissingDeadlines([ReminderDraft(todoID: "m#0", title: "寄出報價", notes: "", due: due)])
        #expect(store.entries[try #require(sync.links["m#0"])]?.draft.due == due)
    }

    @Test func meetingDetailSendsOnlyStructuredDeadlinesToReminders() async throws {
        let world = try World()
        var meeting = try await world.recordedMeeting()
        meeting.metadata.startedAt = ISO8601DateFormatter().date(from: "2026-11-14T10:00:00+08:00")!
        meeting.metadata.timeZoneIdentifier = "Asia/Taipei"
        let timed = try #require(ActionDeadline.parse("2026-11-15T15:30:00+08:00", timeZoneIdentifier: "Asia/Taipei"))
        let day = try #require(ActionDeadline.parse("2026-11-14", timeZoneIdentifier: "Asia/Taipei"))
        meeting.outputs.summary = Summary(decisions: [], discussionPoints: [], actionItems: [
            .init(text: "寄出", owner: nil, sources: [], due: timed),
            .init(text: "今天確認", owner: nil, sources: [], due: day),
            .init(text: "今天收到的資料有問題，請反映", owner: nil, sources: []),
            .init(text: "有空整理", owner: nil, sources: []),
        ])
        try await world.library.save(meeting)
        let detail = MeetingDetailModel(id: meeting.id, library: world.library, voiceprints: world.app.voiceprints,
            queue: world.queue, labels: testLabels, playback: nil, todos: status, reminders: sync)
        await detail.load()
        await detail.addToReminders()
        await detail.load()
        let entries = store.entries.values.map(\.draft)
        #expect(entries.count == 4)
        #expect(entries.first { $0.title == "寄出" }?.due == timed)
        #expect(entries.first { $0.title == "今天確認" }?.due == day)
        #expect(entries.first { $0.title == "今天收到的資料有問題，請反映" }?.due == nil)
        #expect(entries.first { $0.title == "有空整理" }?.due == nil)
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
