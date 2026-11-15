import Foundation
import SQLite3

public actor MeetingIndex {
    private let fileURL: URL
    private var database: SearchDatabase?
    private static let version = 1

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func reconcile(from records: [MeetingLibrary.IndexRecord], user: PersonID? = nil) throws {
        let db = try open()
        let stored = try db.rows("SELECT id, modified, user FROM meetings")
        let live = Set(records.map { $0.meeting.id.description })
        for row in stored where !live.contains(row[0]!) {
            try remove(MeetingID(UUID(uuidString: row[0]!)!))
        }
        let dates = Dictionary(uniqueKeysWithValues: stored.map { ($0[0]!, ($0[1], $0[2])) })
        for record in records {
            let prior = dates[record.meeting.id.description]
            if prior == nil || Double(prior?.0 ?? "") != record.modified.timeIntervalSince1970 || prior?.1 != user?.description {
                try update(record.meeting, modified: record.modified, user: user)
            }
        }
    }

    public func rebuild(from meetings: [Meeting], user: PersonID? = nil) throws {
        let db = try open()
        try db.transaction {
            try db.execute("DELETE FROM content")
            try db.execute("DELETE FROM participants")
            try db.execute("DELETE FROM meetings")
            for meeting in meetings { try insert(meeting, modified: nil, user: user, db: db) }
        }
    }

    public func update(_ meeting: Meeting, modified: Date? = nil, user: PersonID? = nil) throws {
        let db = try open()
        try db.transaction {
            try delete(meeting.id, db: db)
            try insert(meeting, modified: modified, user: user, db: db)
        }
    }

    public func remove(_ id: MeetingID) throws {
        let db = try open()
        try db.transaction { try delete(id, db: db) }
    }

    public func search(_ query: SearchQuery) throws -> [MeetingHits] {
        guard query.limit > 0 else { return [] }
        try Task.checkCancellation()
        let db = try open()
        var people = query.people
        let terms = query.text.split(whereSeparator: \.isWhitespace).map(String.init).filter { term in
            let matches = query.names.filter { $0.value.localizedStandardContains(term) }.map(\.key)
            guard !matches.isEmpty else { return true }
            people.formUnion(matches)
            return false
        }
        var conditions: [String] = []
        var arguments: [String?] = []
        if !people.isEmpty {
            conditions.append("EXISTS (SELECT 1 FROM participants p WHERE p.meeting = m.id AND p.person IN (\(people.map { _ in "?" }.joined(separator: ","))))")
            arguments += people.sorted { $0.description < $1.description }.map(\.description)
        }
        if let range = query.dateRange {
            conditions.append("m.started BETWEEN ? AND ?")
            arguments += [String(range.lowerBound.timeIntervalSince1970), String(range.upperBound.timeIntervalSince1970)]
        }
        if terms.isEmpty {
            let predicate = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            return try db.rows("SELECT m.id, m.title, m.started FROM meetings m \(predicate) ORDER BY m.started DESC, m.id LIMIT ?",
                               arguments + [String(query.limit)]).map {
                MeetingHits(id: MeetingID(UUID(uuidString: $0[0]!)!), title: $0[1]!,
                            startedAt: Date(timeIntervalSince1970: Double($0[2]!)!), hits: [], totalHits: 0)
            }
        }
        let long = terms.filter { $0.count >= 3 }
        let short = terms.filter { $0.count < 3 }
        for term in short {
            conditions.append("c.text LIKE ? ESCAPE '\\'")
            let escaped = term.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            arguments.append("%" + escaped + "%")
        }
        if !long.isEmpty {
            conditions.append("content MATCH ?")
            arguments.append(long.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND "))
        }
        let score = long.isEmpty ? "0.0" : "bm25(content)"
        let rows = try db.rows("""
            SELECT m.id, m.title, m.started, c.kind, c.text, c.utterance, c.time, c.person, \(score)
            FROM content c JOIN meetings m ON m.id = c.meeting
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY CASE c.kind WHEN 'title' THEN 0 WHEN 'cleaned' THEN 2 WHEN 'utterance' THEN 3 ELSE 1 END,
                     \(score), m.started DESC, m.id, c.rowid
            """, arguments)
        var results: [MeetingHits] = []
        var positions: [MeetingID: Int] = [:]
        for row in rows {
            try Task.checkCancellation()
            let id = MeetingID(UUID(uuidString: row[0]!)!)
            let position: Int
            if let existing = positions[id] { position = existing }
            else {
                guard results.count < query.limit else { continue }
                position = results.count
                positions[id] = position
                results.append(MeetingHits(id: id, title: row[1]!, startedAt: Date(timeIntervalSince1970: Double(row[2]!)!), hits: [], totalHits: 0))
            }
            results[position].totalHits += 1
            if results[position].hits.count < 3 {
                results[position].hits.append(.init(kind: .init(rawValue: row[3]!)!, text: row[4]!, terms: terms,
                    utterance: row[5].map(UtteranceID.init), time: row[6].flatMap(Double.init),
                    speaker: row[7].flatMap(UUID.init(uuidString:)).map(PersonID.init)))
            }
        }
        return results
    }

    private func delete(_ id: MeetingID, db: SearchDatabase) throws {
        try db.execute("DELETE FROM content WHERE meeting = ?", [id.description])
        try db.execute("DELETE FROM participants WHERE meeting = ?", [id.description])
        try db.execute("DELETE FROM meetings WHERE id = ?", [id.description])
    }

    private func insert(_ meeting: Meeting, modified: Date?, user: PersonID?, db: SearchDatabase) throws {
        let id = meeting.id.description
        try db.execute("INSERT INTO meetings VALUES (?, ?, ?, ?, ?, ?)", [id, meeting.metadata.title,
            String(meeting.metadata.startedAt.timeIntervalSince1970), String(meeting.metadata.duration),
            modified.map { String($0.timeIntervalSince1970) }, user?.description])
        func person(_ speaker: SpeakerID) -> PersonID? {
            let resolved = meeting.resolve(speaker)
            return resolved == .me ? user : meeting.speaker(resolved)?.person
        }
        for participant in Set(meeting.utterances.compactMap { person($0.speaker) }) {
            try db.execute("INSERT INTO participants VALUES (?, ?)", [id, participant.description])
        }
        func row(_ kind: MeetingHits.Hit.Kind, _ text: String, sources: [UtteranceID] = [], speaker: SpeakerID? = nil) throws {
            let source = sources.first.flatMap(meeting.utterance)
            try db.execute("INSERT INTO content (meeting, kind, text, utterance, time, person) VALUES (?, ?, ?, ?, ?, ?)",
                [id, kind.rawValue, SpeakerMention.substitute(in: text, name: { _ in "" }), source?.id.rawValue,
                 source.map { String($0.range.start) }, (speaker ?? source?.speaker).flatMap(person)?.description])
        }
        try row(.title, meeting.metadata.title)
        for utterance in meeting.utterances { try row(.utterance, utterance.text, sources: [utterance.id], speaker: utterance.speaker) }
        for paragraph in meeting.outputs.cleaned?.paragraphs ?? [] {
            try row(.cleaned, paragraph.text, sources: paragraph.sources, speaker: paragraph.speaker)
        }
        if let summary = meeting.outputs.summary {
            if let headline = summary.headline { try row(.headline, headline) }
            for item in summary.decisions { try row(.decision, item.text, sources: item.sources) }
            for item in summary.discussionPoints { try row(.discussion, item.text, sources: item.sources) }
            for item in summary.actionItems { try row(.action, item.text, sources: item.sources) }
        }
    }

    private func open() throws -> SearchDatabase {
        if let database { return database }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: SearchDatabase?
        do {
            db = try SearchDatabase(fileURL)
            let version = try db!.rows("PRAGMA user_version").first?.first
            let integrity = try db!.rows("PRAGMA quick_check").first?.first
            if version != String(Self.version) || integrity != "ok" { db = nil }
        } catch { db = nil }
        if db == nil {
            for suffix in ["", "-wal", "-shm"] {
                let path = fileURL.path + suffix
                if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
            }
            db = try SearchDatabase(fileURL)
            try db!.execute("CREATE TABLE meetings (id TEXT PRIMARY KEY, title TEXT NOT NULL, started REAL NOT NULL, duration REAL NOT NULL, modified REAL, user TEXT)")
            try db!.execute("CREATE TABLE participants (meeting TEXT NOT NULL, person TEXT NOT NULL, PRIMARY KEY (meeting, person))")
            try db!.execute("CREATE VIRTUAL TABLE content USING fts5(meeting UNINDEXED, kind UNINDEXED, text, utterance UNINDEXED, time UNINDEXED, person UNINDEXED, tokenize='trigram')")
            try db!.execute("PRAGMA user_version = \(Self.version)")
        }
        database = db!
        return db!
    }
}

private final class SearchDatabase {
    private var handle: OpaquePointer?
    private struct Failure: Error { let message: String }

    init(_ url: URL) throws {
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open search index"
            sqlite3_close(handle)
            handle = nil
            throw Failure(message: message)
        }
        sqlite3_busy_timeout(handle, 1_000)
    }

    deinit { sqlite3_close(handle) }

    func rows(_ sql: String, _ arguments: [String?] = []) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in arguments.enumerated() {
            let result = value.map { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                ?? sqlite3_bind_null(statement, Int32(index + 1))
            guard result == SQLITE_OK else { throw failure() }
        }
        var rows: [[String?]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure() }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            })
        }
    }

    func execute(_ sql: String, _ arguments: [String?] = []) throws { _ = try rows(sql, arguments) }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func failure() -> Failure { Failure(message: String(cString: sqlite3_errmsg(handle))) }
}
