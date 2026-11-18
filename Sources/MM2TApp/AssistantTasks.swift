import CryptoKit
import Foundation
import MM2TCore

public struct AssistantTaskRef: Codable, Sendable, Equatable {
    public let meeting: MeetingID
    public let index: Int
    public let fingerprint: String
    public let sources: [UtteranceID]

    public static func fingerprint(_ item: Summary.ActionItem) -> String {
        let parts = [item.text, item.owner?.rawValue ?? "", String(item.due?.date.timeIntervalSince1970 ?? 0),
                     item.due.map { String($0.hasTime) } ?? "", item.due?.timeZoneIdentifier ?? ""]
            + item.sources.map(\.rawValue).sorted()
        let canonical = parts.map { "\($0.utf8.count):\($0)" }.joined()
        return digest(Data(canonical.utf8))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func resolve(in meeting: Meeting) -> Int? {
        guard meeting.id == self.meeting else { return nil }
        let items = meeting.outputs.summary?.actionItems ?? []
        if items.indices.contains(index), Self.fingerprint(items[index]) == fingerprint { return index }
        let matches = items.indices.filter { Self.fingerprint(items[$0]) == fingerprint }
        return matches.count == 1 ? matches[0] : nil
    }
}

public struct TodoSnapshot: Sendable {
    public var done: Set<String> = []
    public var anchors: [String: String] = [:]
    public var anchorMarks: [String: Bool] = [:]
    public var storageError: String?
    public init(done: Set<String> = [], anchors: [String: String] = [:], anchorMarks: [String: Bool]? = nil, storageError: String? = nil) {
        self.done = done
        self.anchors = anchors
        self.anchorMarks = anchorMarks ?? anchors.mapValues { _ in true }
        self.storageError = storageError
    }
}

struct AssistantTaskQuery: Codable, Sendable {
    enum Owner: String, Codable { case me, anyone, unassigned, named }
    enum Status: String, Codable { case unmarked, done, all }
    enum Sort: String, Codable { case due, meetingDate }
    var owner: Owner = .me
    var status: Status = .unmarked
    var people: [String] = []
    var meetingFrom: String?
    var meetingTo: String?
    var dueFrom: String?
    var dueTo: String?
    var sort: Sort = .due
    var cursor: String?
}

struct AssistantTaskRow: Sendable {
    enum Status: String, Sendable { case unmarked, markedDone, legacyDone, needsConfirmation }
    let ref: AssistantTaskRef
    let item: Summary.ActionItem
    let meeting: Meeting
    let owner: String
    let status: Status
}

struct AssistantTaskPage: Sendable {
    let rows: [AssistantTaskRow]
    let total: Int
    let offset: Int
    let nextCursor: String?
    let identityGap: Bool
    let missingSummaries: Int
    let legacyMarks: Int
    let revision: String
    func cursor(after count: Int) -> String? {
        let next = offset + count
        return next < total ? "\(revision):\(next)" : nil
    }
}

enum AssistantQueryError: Error, CustomStringConvertible {
    case invalid(String)
    case timeout
    var description: String { switch self { case .invalid(let text): text; case .timeout: "Assistant request timed out" } }
}

enum AssistantTasks {
    static func range(_ from: String?, _ to: String?) throws -> ClosedRange<Date>? {
        for text in [from, to].compactMap({ $0 }) {
            guard text.count == 10, let parsed = ActionDeadline.parse(text, timeZoneIdentifier: TimeZone.current.identifier),
                  AssistantEngine.day(parsed.date) == text else { throw AssistantQueryError.invalid("Invalid date: \(text)") }
        }
        let range = AssistantEngine.dateRange(from: from, to: to)
        if (from != nil || to != nil) && range == nil { throw AssistantQueryError.invalid("Reversed date range") }
        return range
    }

    static func page(_ query: AssistantTaskQuery, meetings: [Meeting], names: [PersonID: String],
                     user: PersonID?, status: TodoSnapshot, pageSize: Int = 20) throws -> AssistantTaskPage {
        let meetingRange = try range(query.meetingFrom, query.meetingTo)
        let dueRange = try range(query.dueFrom, query.dueTo)
        if query.owner == .named && (query.people.isEmpty || !query.people.allSatisfy({ name in names.values.filter { $0 == name }.count == 1 })) {
            throw AssistantQueryError.invalid("Named owner is unknown or ambiguous; clarify which person")
        }
        var rows: [AssistantTaskRow] = []
        var missing = 0
        var legacy = 0
        for meeting in meetings where meetingRange?.contains(meeting.metadata.startedAt) ?? true {
            guard let summary = meeting.outputs.summary else { missing += 1; continue }
            for (index, item) in summary.actionItems.enumerated() {
                let speaker = item.owner.map(meeting.resolve)
                let person = speaker.flatMap { meeting.speaker($0)?.person }
                let isMe = (speaker == .me && (person == nil || user == nil || person == user)) || (user != nil && person == user)
                let owner = isMe ? "current_user" : person.flatMap { names[$0] } ?? speaker.flatMap { meeting.speaker($0)?.label } ?? "unassigned"
                switch query.owner {
                case .me: if !isMe { continue }
                case .unassigned: if item.owner != nil { continue }
                case .named: if !query.people.contains(person.flatMap { names[$0] } ?? "") { continue }
                case .anyone: break
                }
                if let dueRange, !(item.due.map { dueRange.contains($0.date) } ?? false) { continue }
                let id = "\(meeting.id)#\(index)"
                let fingerprint = AssistantTaskRef.fingerprint(item)
                let state: AssistantTaskRow.Status
                if status.storageError != nil || status.anchors[id].map({ $0 != fingerprint }) == true
                    || status.anchorMarks[id].map({ $0 != status.done.contains(id) }) == true {
                    state = .needsConfirmation
                } else if status.done.contains(id) {
                    state = status.anchors[id] == nil ? .legacyDone : .markedDone
                } else if status.anchors.contains(where: { $0.key.hasPrefix("\(meeting.id)#") && $0.value == fingerprint && status.done.contains($0.key) }) {
                    state = .needsConfirmation
                } else { state = .unmarked }
                if state == .legacyDone { legacy += 1 }
                switch query.status {
                case .unmarked: if state == .markedDone { continue }
                case .done: if state == .unmarked { continue }
                case .all: break
                }
                rows.append(.init(ref: .init(meeting: meeting.id, index: index, fingerprint: fingerprint, sources: item.sources),
                                  item: item, meeting: meeting, owner: owner, status: state))
            }
        }
        rows.sort {
            if query.sort == .due, $0.item.due?.date != $1.item.due?.date {
                return ($0.item.due?.date ?? .distantFuture) < ($1.item.due?.date ?? .distantFuture)
            }
            if $0.meeting.metadata.startedAt != $1.meeting.metadata.startedAt { return $0.meeting.metadata.startedAt > $1.meeting.metadata.startedAt }
            if $0.ref.meeting != $1.ref.meeting { return $0.ref.meeting.description < $1.ref.meeting.description }
            return $0.ref.index < $1.ref.index
        }
        var key = query
        key.cursor = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var revision = try encoder.encode(key)
        revision.append(contentsOf: "|\(missing)|\(legacy)|\(user?.description ?? "unknown")".utf8)
        for row in rows { revision.append(contentsOf: "|\(row.ref.meeting)#\(row.ref.index):\(row.ref.fingerprint):\(row.status.rawValue):\(row.owner)".utf8) }
        let hash = AssistantTaskRef.digest(revision)
        var offset = 0
        if let cursor = query.cursor {
            let parts = cursor.split(separator: ":")
            guard parts.count == 2, parts[0] == hash, let value = Int(parts[1]), value >= 0, value <= rows.count else {
                throw AssistantQueryError.invalid("Cursor expired or belongs to another query; restart without cursor")
            }
            offset = value
        }
        let end = min(rows.count, offset + max(1, pageSize))
        return .init(rows: Array(rows[offset..<end]), total: rows.count, offset: offset,
                     nextCursor: end < rows.count ? "\(hash):\(end)" : nil, identityGap: user == nil,
                     missingSummaries: missing, legacyMarks: legacy, revision: hash)
    }
}
