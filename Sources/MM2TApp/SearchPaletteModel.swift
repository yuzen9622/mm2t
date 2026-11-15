import Foundation
import MM2TCore
import Observation
import OSLog

@MainActor @Observable
public final class SearchPaletteModel {
    public enum Picker: Equatable { case people, dates }
    public enum DateFilter: CaseIterable, Sendable {
        case today, last7Days, last30Days, last3Months, thisYear

        public func range(now: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
            let today = calendar.startOfDay(for: now)
            let start: Date
            switch self {
            case .today: start = today
            case .last7Days: start = calendar.date(byAdding: .day, value: -6, to: today)!
            case .last30Days: start = calendar.date(byAdding: .day, value: -29, to: today)!
            case .last3Months: start = calendar.date(byAdding: .month, value: -3, to: today)!
            case .thisYear: start = calendar.dateInterval(of: .year, for: now)!.start
            }
            return start...now
        }
    }

    public struct Destination: Equatable {
        public let meeting: MeetingID
        public let utterance: UtteranceID?
    }

    public struct Row: Identifiable, Equatable {
        public enum ID: Hashable {
            case meeting(MeetingID), hit(MeetingID, Int), more(MeetingID), person(PersonID), date(DateFilter), ask
        }
        public enum Content: Equatable {
            case meeting(MeetingHits), hit(MeetingHits, Int), more(MeetingHits), person(PersonID, String), date(DateFilter), ask(String)
        }
        public let id: ID
        public let content: Content
    }

    public var query = "" { didSet { if query != oldValue { changed() } } }
    public var person: PersonID? { didSet { if person != oldValue { changed() } } }
    public var date: DateFilter? { didSet { if date != oldValue { changed() } } }
    public private(set) var picker: Picker?
    public private(set) var rows: [Row] = []
    public private(set) var selection: Row.ID?
    public private(set) var names: [PersonID: String] = [:]
    public private(set) var failed = false
    public var ask: ((String) -> Void)?
    public var isRecent: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && person == nil && date == nil }

    @ObservationIgnored private let index: MeetingIndex
    @ObservationIgnored private let voiceprints: VoiceprintStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var results: [MeetingHits] = []
    private static let logger = Logger(subsystem: "dev.mm2t.app", category: "Search")

    public init(index: MeetingIndex, voiceprints: VoiceprintStore, now: @escaping () -> Date = Date.init) {
        self.index = index
        self.voiceprints = voiceprints
        self.now = now
    }

    deinit { searchTask?.cancel() }

    public func open() async {
        query = ""
        person = nil
        date = nil
        picker = nil
        results = []
        rows = []
        selection = nil
        await refresh()
    }

    public func close() {
        revision += 1
        searchTask?.cancel()
        searchTask = nil
    }

    public func show(_ picker: Picker) {
        self.picker = picker
        failed = false
        flatten()
    }

    public func select(_ id: Row.ID) {
        guard rows.contains(where: { $0.id == id }) else { return }
        selection = id
    }

    public func move(_ offset: Int) {
        guard !rows.isEmpty else { selection = nil; return }
        let current = selection.flatMap { selected in rows.firstIndex { $0.id == selected } } ?? 0
        selection = rows[((current + offset) % rows.count + rows.count) % rows.count].id
    }

    public func activate(_ id: Row.ID? = nil) -> Destination? {
        guard let selected = id ?? selection, let row = rows.first(where: { $0.id == selected }) else { return nil }
        switch row.content {
        case .ask(let question): ask?(question)
        case .meeting(let meeting), .more(let meeting):
            return Destination(meeting: meeting.id, utterance: nil)
        case .hit(let meeting, let index):
            return Destination(meeting: meeting.id, utterance: meeting.hits[index].utterance)
        case .person(let id, _):
            picker = nil
            person = id
            flatten()
        case .date(let filter):
            picker = nil
            date = filter
            flatten()
        }
        return nil
    }

    public func refresh() async {
        searchTask?.cancel()
        revision += 1
        await search(revision: revision)
    }

    private func changed() {
        selection = rows.first?.id
        revision += 1
        let request = revision
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
                await self?.search(revision: request)
            } catch {}
        }
    }

    private func search(revision request: Int) async {
        let text = query
        let person = person
        let range = date?.range(now: now())
        let recent = isRecent
        let names = await voiceprints.names().filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        do {
            let found = try await index.search(.init(text: text, people: Set(person.map { [$0] } ?? []),
                dateRange: range, limit: recent ? 5 : 30, names: names))
            guard request == revision, !Task.isCancelled else { return }
            self.names = names
            results = found
            failed = false
            flatten()
        } catch is CancellationError {
        } catch {
            guard request == revision, !Task.isCancelled else { return }
            failed = true
            let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
            rows = question.isEmpty ? [] : [Row(id: .ask, content: .ask(question))]
            selection = rows.first?.id
            Self.logger.error("Search failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func flatten() {
        let people = names.sorted {
            let order = $0.value.localizedStandardCompare($1.value)
            return order == .orderedSame ? $0.key.description < $1.key.description : order == .orderedAscending
        }.map { Row(id: .person($0.key), content: .person($0.key, $0.value)) }
        switch picker {
        case .people: rows = people
        case .dates: rows = DateFilter.allCases.map { Row(id: .date($0), content: .date($0)) }
        case nil:
            rows = results.flatMap { meeting in
                var group = [Row(id: .meeting(meeting.id), content: .meeting(meeting))]
                for position in meeting.hits.indices {
                    group.append(Row(id: .hit(meeting.id, position), content: .hit(meeting, position)))
                }
                if meeting.totalHits > meeting.hits.count {
                    group.append(Row(id: .more(meeting.id), content: .more(meeting)))
                }
                return group
            }
            if isRecent { rows += people.prefix(5) }
            let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !question.isEmpty { rows.append(Row(id: .ask, content: .ask(question))) }
        }
        selection = rows.first?.id
    }
}
