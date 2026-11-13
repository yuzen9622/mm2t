import AppKit
import EventKit
import Foundation
import Observation

// MARK: Boundary

public enum RemindersAccess: Hashable, Sendable {
    case notDetermined
    case granted
    /// The user refused, or macOS restricts the app; only System Settings can change it.
    case denied
}

/// A reminder to create for one to-do.
public struct ReminderDraft: Hashable, Sendable {
    public let todoID: String
    public let title: String
    public let notes: String
    public let due: Date?
    public let isCompleted: Bool

    public init(todoID: String, title: String, notes: String, due: Date? = nil, isCompleted: Bool = false) {
        self.todoID = todoID
        self.title = title
        self.notes = notes
        self.due = due
        self.isCompleted = isCompleted
    }
}

public enum ReminderError: Error, Equatable, Sendable {
    /// The reminder was deleted in Reminders.
    case notFound
    case denied
}

/// The Reminders app's data. The live conformance uses EventKit; tests script it.
public protocol ReminderStore: Sendable {
    var access: RemindersAccess { get }
    func requestAccess() async -> Bool
    /// Creates the reminder in the list named `list`, making the list if it is missing; returns its identifier.
    func create(_ draft: ReminderDraft, inList list: String) async throws -> String
    /// Whether each reminder is completed; a reminder that no longer exists is left out.
    func completion(of ids: [String]) async -> [String: Bool]
    func setCompleted(_ id: String, _ completed: Bool) async throws
    /// Fires whenever anything in Reminders changes.
    var changes: AsyncStream<Void> { get }
}

public final class SystemReminders: ReminderStore, @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public var access: RemindersAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    public func requestAccess() async -> Bool {
        if access == .granted { return true }
        return (try? await store.requestFullAccessToReminders()) == true
    }

    public func create(_ draft: ReminderDraft, inList list: String) async throws -> String {
        guard access == .granted else { throw ReminderError.denied }
        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.calendar = try calendar(named: list)
        if let due = draft.due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        }
        reminder.isCompleted = draft.isCompleted
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    private func calendar(named name: String) throws -> EKCalendar {
        if let found = store.calendars(for: .reminder).first(where: { $0.title == name && $0.allowsContentModifications }) {
            return found
        }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = name
        guard let source = store.defaultCalendarForNewReminders()?.source ?? store.sources.first(where: { $0.sourceType == .local })
        else { throw ReminderError.denied }
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return calendar
    }

    public func completion(of ids: [String]) async -> [String: Bool] {
        var result: [String: Bool] = [:]
        for id in ids {
            if let reminder = store.calendarItem(withIdentifier: id) as? EKReminder { result[id] = reminder.isCompleted }
        }
        return result
    }

    public func setCompleted(_ id: String, _ completed: Bool) async throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw ReminderError.notFound }
        guard reminder.isCompleted != completed else { return }
        reminder.isCompleted = completed
        try store.save(reminder, commit: true)
    }

    public var changes: AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged, object: self.store).map({ _ in () }) {
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: Sync

/// Keeps to-dos and their reminders in step. A link is created by the user (`add`); after that,
/// completion follows in both directions. A reminder deleted in Reminders only drops the link.
@MainActor @Observable
public final class RemindersSync {
    public static let defaultList = "mm2t"

    public private(set) var access: RemindersAccess
    public private(set) var links: [String: String]
    /// Set when the last `add` could not create every reminder.
    public private(set) var failed = false

    @ObservationIgnored private let store: any ReminderStore
    @ObservationIgnored private let status: TodoStatus
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let list: String
    @ObservationIgnored private var tail: Task<Void, Never> = Task {}
    @ObservationIgnored private var watching: [Task<Void, Never>] = []

    public init(store: any ReminderStore, status: TodoStatus, file: URL, list: String = RemindersSync.defaultList) {
        self.store = store
        self.status = status
        self.file = file
        self.list = list
        access = store.access
        links = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))) ?? [:]
        status.onToggle = { [weak self] id, done in self?.push(id, done) }
    }

    /// Starts following Reminders: on every change in it and whenever the app comes forward.
    public func start() {
        guard watching.isEmpty else { return }
        watching = [
            Task { [weak self, store] in
                for await _ in store.changes { await self?.reconcile() }
            },
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                    await self?.reconcile()
                }
            },
        ]
        Task { await reconcile() }
    }

    public func isLinked(_ todoID: String) -> Bool { links[todoID] != nil }

    public func requestAccess() async {
        _ = await store.requestAccess()
        access = store.access
    }

    /// Creates a reminder for each draft that has none yet.
    public func add(_ drafts: [ReminderDraft]) async {
        await serialized {
            if self.store.access == .notDetermined { _ = await self.store.requestAccess() }
            self.access = self.store.access
            guard self.access == .granted else { return }
            self.failed = false
            for draft in drafts where self.links[draft.todoID] == nil {
                var draft = draft
                draft = ReminderDraft(todoID: draft.todoID, title: draft.title, notes: draft.notes, due: draft.due,
                                      isCompleted: self.status.isDone(draft.todoID))
                do {
                    self.links[draft.todoID] = try await self.store.create(draft, inList: self.list)
                    self.save()
                } catch {
                    self.failed = true
                }
            }
        }
    }

    /// Pulls completion from Reminders into the to-dos and drops links to deleted reminders.
    public func reconcile() async {
        await serialized {
            self.access = self.store.access
            guard self.access == .granted, !self.links.isEmpty else { return }
            let states = await self.store.completion(of: Array(self.links.values))
            var changed = false
            for (todo, reminder) in self.links {
                guard let completed = states[reminder] else {
                    self.links[todo] = nil
                    changed = true
                    continue
                }
                self.status.set(todo, done: completed)
            }
            if changed { self.save() }
        }
    }

    private func push(_ todoID: String, _ done: Bool) {
        guard let reminder = links[todoID] else { return }
        enqueue {
            do {
                try await self.store.setCompleted(reminder, done)
            } catch ReminderError.notFound {
                if self.links[todoID] == reminder {
                    self.links[todoID] = nil
                    self.save()
                }
            } catch {}
        }
    }

    /// Runs `work` after everything queued before it, so a change pushed to Reminders is not undone by
    /// a read that started earlier.
    @discardableResult
    private func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous.value
            await work()
        }
        tail = task
        return task
    }

    private func serialized(_ work: @escaping @MainActor () async -> Void) async {
        await enqueue(work).value
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(links).write(to: file, options: .atomic)
    }
}
