import EventKit
import Foundation
import MM2TCore
import Observation

// MARK: Calendar

public enum CalendarAccess: Sendable, Equatable {
    case notDetermined
    case granted
    case denied
}

public struct CalendarEvent: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let calendar: String
    /// The video-call address found in the event, if any.
    public let link: URL?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool, calendar: String, link: URL?) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendar = calendar
        self.link = link
    }
}

/// The calendars the Mac already syncs (iCloud, Google, Exchange accounts in System Settings).
public protocol CalendarProviding: Sendable {
    var access: CalendarAccess { get }
    /// Shows the system prompt the first time.
    func requestAccess() async -> Bool
    func events(from start: Date, to end: Date) async -> [CalendarEvent]
}

public struct NoCalendar: CalendarProviding {
    public init() {}
    public var access: CalendarAccess { .denied }
    public func requestAccess() async -> Bool { false }
    public func events(from start: Date, to end: Date) async -> [CalendarEvent] { [] }
}

public final class SystemCalendar: CalendarProviding, @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    public func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    public func events(from start: Date, to end: Date) async -> [CalendarEvent] {
        guard access == .granted else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }.map { event in
            CalendarEvent(
                id: "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)",
                title: event.title ?? "", start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                calendar: event.calendar?.title ?? "",
                link: MeetingLink.find(in: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }))
        }
    }
}

// MARK: Rows

/// An action item from a meeting's summary. `id` stays the same across reloads so "done" sticks.
public struct TodoRow: Hashable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let owner: String?
    public let meeting: MeetingID
    public let meetingTitle: String
    public let date: Date
    public let isDone: Bool
}

public struct DashboardStats: Hashable, Sendable {
    public var meetings = 0
    public var recorded: TimeInterval = 0
    /// Characters of transcript, a count that means the same for Mandarin and English.
    public var characters = 0
    public var people = 0
    public var terms = 0
    /// The user's part of all talk time in meetings where the mic was theirs alone; nil with no such meeting.
    public var myShare: Double?
}

public struct ActivityDay: Hashable, Sendable, Identifiable {
    public let date: Date
    public let minutes: Double
    public var id: Date { date }
}

public struct VoiceRow: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let seconds: TimeInterval
    public let meetings: Int
    /// Part of the longest talker's time, for the bar.
    public let fraction: Double
}

public struct TermRow: Hashable, Sendable, Identifiable {
    public let term: String
    public let count: Int
    public var id: String { term }
}

// MARK: Model

/// The home screen: what the user owes, what is on their calendar, and what their meetings add up to.
@MainActor @Observable
public final class DashboardModel {
    public private(set) var todos: [TodoRow] = []
    public private(set) var stats = DashboardStats()
    /// One entry per day, oldest first, ending today.
    public private(set) var activity: [ActivityDay] = []
    public private(set) var voices: [VoiceRow] = []
    public private(set) var terms: [TermRow] = []
    public private(set) var events: [CalendarEvent] = []
    public private(set) var calendarAccess: CalendarAccess
    public var meLabel = "Me"

    public static let activityDays = 84

    @ObservationIgnored private let library: MeetingLibrary
    @ObservationIgnored private let voiceprints: VoiceprintStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let calendar: any CalendarProviding
    @ObservationIgnored private let todosFile: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var done: Set<String>

    public init(library: MeetingLibrary, voiceprints: VoiceprintStore, settings: SettingsStore,
                calendar: any CalendarProviding, todosFile: URL, now: @escaping () -> Date) {
        self.library = library
        self.voiceprints = voiceprints
        self.settings = settings
        self.calendar = calendar
        self.todosFile = todosFile
        self.now = now
        calendarAccess = calendar.access
        done = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: todosFile))) ?? [])
    }

    public func reload() async {
        let names = await voiceprints.names()
        let meetings = ((try? await library.list()) ?? []).filter { $0.status == .completed }
        let vocabulary = settings.settings.vocabulary
        let snapshot = Self.snapshot(meetings, names: names, vocabulary: vocabulary, done: done, me: meLabel, today: now())
        todos = snapshot.todos
        stats = snapshot.stats
        activity = snapshot.activity
        voices = snapshot.voices
        terms = snapshot.terms
        await reloadCalendar()
    }

    public func reloadCalendar() async {
        calendarAccess = calendar.access
        let start = now()
        events = await calendar.events(from: start.addingTimeInterval(-3600), to: Calendar.current.startOfDay(for: start).addingTimeInterval(2 * 86_400))
            .filter { $0.end > start }
    }

    public func connectCalendar() async {
        _ = await calendar.requestAccess()
        await reloadCalendar()
    }

    public func toggle(_ todo: TodoRow) {
        if !done.insert(todo.id).inserted { done.remove(todo.id) }
        try? FileManager.default.createDirectory(at: todosFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(done.sorted()).write(to: todosFile, options: .atomic)
        todos = todos.map {
            $0.id == todo.id ? TodoRow(id: $0.id, text: $0.text, owner: $0.owner, meeting: $0.meeting,
                                       meetingTitle: $0.meetingTitle, date: $0.date, isDone: !$0.isDone) : $0
        }
    }

    struct Snapshot {
        var todos: [TodoRow] = []
        var stats = DashboardStats()
        var activity: [ActivityDay] = []
        var voices: [VoiceRow] = []
        var terms: [TermRow] = []
    }

    /// `meetings` are completed ones, newest first.
    static func snapshot(_ meetings: [Meeting], names: [PersonID: String], vocabulary: [String],
                         done: Set<String>, me: String, today: Date) -> Snapshot {
        var result = Snapshot()
        var talk: [String: (name: String, seconds: TimeInterval, meetings: Int)] = [:]
        var mine: TimeInterval = 0, alongsideMe: TimeInterval = 0
        var minutes: [Date: Double] = [:]
        var counts = [Int](repeating: 0, count: vocabulary.count)
        let calendar = Calendar.current

        for meeting in meetings {
            let renderer = MeetingRenderer(meeting: meeting, names: names)
            let name = { (id: SpeakerID) in meeting.resolve(id) == .me ? me : renderer.displayName(id) }
            for (index, item) in (meeting.outputs.summary?.actionItems ?? []).enumerated() {
                let id = "\(meeting.id)#\(index)"
                result.todos.append(TodoRow(
                    id: id, text: SpeakerMention.substitute(in: item.text, name: name), owner: item.owner.map(name),
                    meeting: meeting.id, meetingTitle: meeting.metadata.title, date: meeting.metadata.startedAt,
                    isDone: done.contains(id)))
            }

            result.stats.meetings += 1
            result.stats.recorded += meeting.metadata.duration
            minutes[calendar.startOfDay(for: meeting.metadata.startedAt), default: 0] += meeting.metadata.duration / 60

            var spoke: [String: TimeInterval] = [:]
            for utterance in meeting.utterances {
                result.stats.characters += utterance.text.count
                for (index, term) in vocabulary.enumerated() {
                    counts[index] += utterance.text.components(separatedBy: term).count - 1
                }
                let speaker = meeting.resolve(utterance.speaker)
                let key: String
                if speaker == .me {
                    key = "me"
                    talk[key, default: (me, 0, 0)].seconds += utterance.range.duration
                } else if let person = meeting.speaker(speaker)?.person, let personName = names[person] {
                    key = person.description
                    talk[key, default: (personName, 0, 0)].seconds += utterance.range.duration
                } else {
                    key = "unnamed"
                }
                spoke[key, default: 0] += utterance.range.duration
            }
            for key in spoke.keys where key != "unnamed" { talk[key]?.meetings += 1 }
            if let myTime = spoke["me"] {
                mine += myTime
                alongsideMe += spoke.values.reduce(0, +)
            }
        }

        result.stats.people = names.count
        result.stats.terms = vocabulary.count
        result.stats.myShare = alongsideMe > 0 ? mine / alongsideMe : nil
        let start = calendar.startOfDay(for: today)
        result.activity = (0..<activityDays).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: start).map { ActivityDay(date: $0, minutes: minutes[$0] ?? 0) }
        }
        let longest = talk.values.map(\.seconds).max() ?? 0
        result.voices = talk.sorted { $0.value.seconds > $1.value.seconds }.prefix(6).map {
            VoiceRow(id: $0.key, name: $0.value.name, seconds: $0.value.seconds, meetings: $0.value.meetings,
                     fraction: longest > 0 ? $0.value.seconds / longest : 0)
        }
        result.terms = zip(vocabulary, counts).filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(14).map { TermRow(term: $0.0, count: $0.1) }
        return result
    }
}
