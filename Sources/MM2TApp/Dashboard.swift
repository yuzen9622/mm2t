import Foundation
import MM2TCore
import Observation

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

    public init(term: String, count: Int) {
        self.term = term
        self.count = count
    }
}

public struct CalendarSourceState: Hashable, Sendable, Identifiable {
    public let kind: CalendarSourceKind
    public var connection: CalendarConnection
    public var problem: CalendarProblem?
    public var id: CalendarSourceKind { kind }
}

// MARK: Model

/// The home screen: what the user owes, what is on their calendar, and what their meetings add up to.
@MainActor @Observable
public final class DashboardModel {
    /// Every to-do with its done state as it is now.
    public var todos: [TodoRow] {
        loadedTodos.map { TodoRow(id: $0.id, text: $0.text, owner: $0.owner, meeting: $0.meeting, meetingTitle: $0.meetingTitle,
                                  date: $0.date, isDone: status.isDone($0.id)) }
    }
    private var loadedTodos: [TodoRow] = []
    public private(set) var stats = DashboardStats()
    /// One entry per day, oldest first, ending today.
    public private(set) var activity: [ActivityDay] = []
    public private(set) var voices: [VoiceRow] = []
    public private(set) var terms: [TermRow] = []
    /// Every calendar source in display order, with its connection.
    public private(set) var calendarSources: [CalendarSourceState]
    /// The first day of the month on screen.
    public private(set) var month: Date
    public private(set) var selectedDay: Date
    /// Events of every connected source across the six weeks the month grid shows.
    public private(set) var monthEvents: [CalendarEvent] = []
    public private(set) var isLoadingCalendar = false
    public var meLabel = "Me"

    public static let activityDays = 84
    /// How many of the most used terms the word cloud shows.
    public static let cloudSize = 40

    @ObservationIgnored private let library: MeetingLibrary
    @ObservationIgnored private let voiceprints: VoiceprintStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let calendars: [any CalendarSource]
    @ObservationIgnored private var calendarLoad = 0
    @ObservationIgnored private let status: TodoStatus
    @ObservationIgnored private let now: () -> Date

    public init(library: MeetingLibrary, voiceprints: VoiceprintStore, settings: SettingsStore,
                calendars: [any CalendarSource], todosFile: URL, status: TodoStatus? = nil,
                now: @escaping () -> Date) {
        self.library = library
        self.voiceprints = voiceprints
        self.settings = settings
        self.calendars = calendars
        self.status = status ?? TodoStatus(file: todosFile)
        self.now = now
        calendarSources = calendars.map { CalendarSourceState(kind: $0.kind, connection: .disconnected) }
        let today = Calendar.current.startOfDay(for: now())
        month = Calendar.current.dateInterval(of: .month, for: today)?.start ?? today
        selectedDay = today
    }

    public func reload() async {
        let names = await voiceprints.names()
        let meetings = ((try? await library.list()) ?? []).filter { $0.status == .completed }
        let vocabulary = settings.settings.vocabulary
        let snapshot = Self.snapshot(meetings, names: names, vocabulary: vocabulary, done: status.done, me: meLabel, today: now())
        loadedTodos = snapshot.todos
        stats = snapshot.stats
        activity = snapshot.activity
        voices = snapshot.voices
        terms = snapshot.terms
        await reloadCalendar()
    }

    /// Re-reads every source's connection, then the events of the month on screen.
    public func reloadCalendar() async {
        for (index, source) in calendars.enumerated() where calendarSources[index].connection != .connecting {
            calendarSources[index].connection = await source.status()
        }
        await loadEvents()
    }

    public var hasConnectedCalendar: Bool { calendarSources.contains { $0.connection == .connected } }

    /// The six weeks of days the month grid shows.
    public var gridDays: [Date] { MonthGrid.days(around: month, calendar: .current) }

    /// Events that touch `day`, all-day ones first.
    public func events(on day: Date) -> [CalendarEvent] {
        let start = Calendar.current.startOfDay(for: day)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return [] }
        return monthEvents.filter { $0.start < end && $0.end > start }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }

    public func select(_ day: Date) {
        selectedDay = Calendar.current.startOfDay(for: day)
        if !Calendar.current.isDate(day, equalTo: month, toGranularity: .month) {
            month = Calendar.current.dateInterval(of: .month, for: day)?.start ?? month
            Task { await loadEvents() }
        }
    }

    /// Moves the grid `offset` months and selects that month's first day (today, when it is this month).
    public func showMonth(_ offset: Int) async {
        guard let target = Calendar.current.date(byAdding: .month, value: offset, to: month) else { return }
        month = target
        let today = Calendar.current.startOfDay(for: now())
        selectedDay = Calendar.current.isDate(today, equalTo: target, toGranularity: .month) ? today : target
        await loadEvents()
    }

    public func showToday() async {
        let today = Calendar.current.startOfDay(for: now())
        let moved = !Calendar.current.isDate(today, equalTo: month, toGranularity: .month)
        month = Calendar.current.dateInterval(of: .month, for: today)?.start ?? today
        selectedDay = today
        if moved { await loadEvents() }
    }

    public func connect(_ kind: CalendarSourceKind) async {
        guard let index = calendars.firstIndex(where: { $0.kind == kind }),
              calendarSources[index].connection != .connecting else { return }
        calendarSources[index].connection = .connecting
        calendarSources[index].problem = nil
        do {
            try await calendars[index].connect()
        } catch CalendarError.cancelled {
        } catch CalendarError.unreachable {
            calendarSources[index].problem = .unreachable
        } catch let failure as GoogleOAuthFailure {
            calendarSources[index].problem = .googleOAuth(failure)
        } catch {
            calendarSources[index].problem = .signInFailed
        }
        calendarSources[index].connection = await calendars[index].status()
        await loadEvents()
    }

    public func disconnect(_ kind: CalendarSourceKind) async {
        guard let index = calendars.firstIndex(where: { $0.kind == kind }) else { return }
        await calendars[index].disconnect()
        calendarSources[index].problem = nil
        calendarSources[index].connection = await calendars[index].status()
        // Reloaded rather than filtered: a merged-away copy from another source has to come back.
        await loadEvents()
    }

    private func loadEvents() async {
        calendarLoad += 1
        let load = calendarLoad
        let days = gridDays
        guard let first = days.first, let last = days.last.flatMap({ Calendar.current.date(byAdding: .day, value: 1, to: $0) }) else { return }
        let connected = calendars.enumerated().filter { calendarSources[$0.offset].connection == .connected }
        guard !connected.isEmpty else {
            monthEvents = []
            isLoadingCalendar = false
            return
        }
        isLoadingCalendar = true
        var lists: [[CalendarEvent]] = []
        var problems: [CalendarSourceKind: CalendarProblem?] = [:]
        await withTaskGroup(of: (CalendarSourceKind, Result<[CalendarEvent], Error>).self) { group in
            for (_, source) in connected {
                group.addTask {
                    do { return (source.kind, .success(try await source.events(from: first, to: last))) }
                    catch { return (source.kind, .failure(error)) }
                }
            }
            for await (kind, result) in group {
                switch result {
                case .success(let events):
                    lists.append(events)
                    problems[kind] = .some(nil)
                case .failure(CalendarError.signedOut):
                    problems[kind] = .signedOut
                case .failure(let failure as GoogleOAuthFailure):
                    problems[kind] = .googleOAuth(failure)
                case .failure:
                    problems[kind] = .unreachable
                }
            }
        }
        guard load == calendarLoad else { return }
        monthEvents = CalendarMerge.merge(lists)
        isLoadingCalendar = false
        for (index, source) in calendars.enumerated() {
            guard let problem = problems[source.kind] else { continue }
            calendarSources[index].problem = problem
            if problem == .signedOut { calendarSources[index].connection = await source.status() }
        }
    }

    public func toggle(_ todo: TodoRow) {
        status.toggle(todo.id)
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
        result.terms = zip(vocabulary, counts).filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(Self.cloudSize).map { TermRow(term: $0.0, count: $0.1) }
        return result
    }
}
