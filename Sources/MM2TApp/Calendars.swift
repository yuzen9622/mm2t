import EventKit
import Foundation
import MM2TCore

// MARK: Sources

/// Where a calendar comes from. A user may connect any number of them.
public enum CalendarSourceKind: String, CaseIterable, Hashable, Sendable {
    /// The calendars macOS already syncs (iCloud and the accounts in Internet Accounts), via EventKit.
    case apple
    case google
    case microsoft
}

public enum CalendarConnection: Hashable, Sendable {
    /// This build has no OAuth client ID for the service.
    case unavailable
    case disconnected
    case connecting
    case connected
    /// macOS refused access to its calendars.
    case denied
}

/// Why the last connect or fetch of a source went wrong.
public enum CalendarProblem: Hashable, Sendable {
    case signInFailed
    case unreachable
    /// The service no longer accepts the stored sign-in; it was removed and the source disconnected.
    case signedOut
}

public enum CalendarError: Error, Equatable, Sendable {
    case unavailable
    case cancelled
    case signInFailed
    case unreachable
    case signedOut
}

public struct CalendarEvent: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date
    /// Exclusive; an all-day event ends at the midnight after its last day.
    public let end: Date
    public let isAllDay: Bool
    /// The calendar's own name within its source ("Work", "Family"), when the source has one.
    public let calendar: String
    /// The video-call address found in the event, if any.
    public let link: URL?
    public let source: CalendarSourceKind
    /// The iCalendar UID, shared by every copy of the same meeting across services.
    public let uid: String?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool, calendar: String, link: URL?,
                source: CalendarSourceKind, uid: String? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendar = calendar
        self.link = link
        self.source = source
        self.uid = uid
    }

    func with(link: URL?) -> CalendarEvent {
        CalendarEvent(id: id, title: title, start: start, end: end, isAllDay: isAllDay, calendar: calendar, link: link,
                      source: source, uid: uid)
    }
}

/// One place events come from. Live conformances talk to EventKit or a web API; tests script them.
public protocol CalendarSource: Sendable {
    var kind: CalendarSourceKind { get }
    /// The state as stored, without prompting or touching the network.
    func status() async -> CalendarConnection
    /// Asks for access: the system prompt, or a sign-in in the browser.
    func connect() async throws
    /// Forgets the source's access; for a web service this removes the stored sign-in.
    func disconnect() async
    func events(from start: Date, to end: Date) async throws -> [CalendarEvent]
}

// MARK: Pure parts

public enum CalendarMerge {
    /// One list across sources, by start time. A meeting seen through two sources (a Google account
    /// synced to the Mac and also connected directly) is kept once: the direct copy, with a call link
    /// from whichever copy has one.
    public static func merge(_ lists: [[CalendarEvent]]) -> [CalendarEvent] {
        var result: [CalendarEvent] = []
        for event in lists.joined().sorted(by: { rank($0.source) < rank($1.source) }) {
            if let index = result.firstIndex(where: { same($0, event) }) {
                if result[index].link == nil, event.link != nil { result[index] = result[index].with(link: event.link) }
            } else {
                result.append(event)
            }
        }
        return result.sorted { ($0.start, $0.end, $0.title) < ($1.start, $1.end, $1.title) }
    }

    static func same(_ a: CalendarEvent, _ b: CalendarEvent) -> Bool {
        guard a.isAllDay == b.isAllDay, abs(a.start.timeIntervalSince(b.start)) < 60 else { return false }
        if let x = a.uid, let y = b.uid, x == y { return true }
        return normalized(a.title) == normalized(b.title)
    }

    private static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A service's own API carries richer call details than its copy synced into macOS.
    private static func rank(_ source: CalendarSourceKind) -> Int {
        source == .apple ? 1 : 0
    }
}

public enum MonthGrid {
    /// Six weeks of days covering the month that contains `date`, starting on the calendar's first
    /// weekday, so the grid keeps one height from month to month.
    public static func days(around date: Date, calendar: Calendar) -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: date)?.start else { return [] }
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        guard let first = calendar.date(byAdding: .day, value: -lead, to: month) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }
}

// MARK: Apple

/// The calendars the Mac already syncs. macOS keeps the permission, so "disconnect" only hides them.
public final class SystemCalendar: CalendarSource, @unchecked Sendable {
    public let kind = CalendarSourceKind.apple
    private let store = EKEventStore()
    private let defaults: UserDefaults
    private static let hiddenKey = "MM2TAppleCalendarHidden"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func status() async -> CalendarConnection {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: defaults.bool(forKey: Self.hiddenKey) ? .disconnected : .connected
        case .notDetermined: .disconnected
        default: .denied
        }
    }

    public func connect() async throws {
        defaults.set(false, forKey: Self.hiddenKey)
        guard EKEventStore.authorizationStatus(for: .event) != .fullAccess else { return }
        guard (try? await store.requestFullAccessToEvents()) == true else { throw CalendarError.cancelled }
    }

    public func disconnect() async {
        defaults.set(true, forKey: Self.hiddenKey)
    }

    public func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        guard await status() == .connected else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            CalendarEvent(
                id: "apple:\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)",
                title: event.title ?? "", start: event.startDate,
                // EventKit may end an all-day event at 23:59:59 of its last day; make it the next midnight.
                end: event.isAllDay
                    ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: event.endDate.addingTimeInterval(-1))) ?? event.endDate
                    : event.endDate,
                isAllDay: event.isAllDay, calendar: event.calendar?.title ?? "",
                link: MeetingLink.find(in: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }),
                source: .apple, uid: event.calendarItemExternalIdentifier)
        }
    }
}
