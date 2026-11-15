import Foundation
import SQLite3
import Testing
@testable import MM2TCore

@Suite struct MeetingIndexTests {
    private func fixture(title: String = "Planning", text: String = "我們討論年度預算，以及資料安全。Microarchitecture review.",
                         date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> Meeting {
        var meeting = Meeting(id: MeetingID(), metadata: .init(title: title, startedAt: date, duration: 60),
                              audio: .init(micFile: "mic.wav", remoteFile: "remote.wav"), highlights: [])
        meeting.utterances = [Utterance(id: UtteranceID("u1"), speaker: .me, range: .init(start: 10, end: 20),
                                        isOverlapping: false, text: text, words: [])]
        return meeting
    }

    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "index-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func substringsAndLiteralOperators() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = MeetingIndex(fileURL: root.appending(path: "search.sqlite"))
        let meeting = fixture(text: "年度預算 資料安全 Microarchitecture AND a*b a-b 100% a_b \"quoted\"")
        try await index.update(meeting)
        for query in ["預算", "資料安全", "architecture", "ro", "AND", "a*b", "a-b", "100%", "a_b", "\"quoted\""] {
            let hits = try await index.search(.init(text: query))
            #expect(hits.map(\.id) == [meeting.id], "query: \(query)")
            #expect(hits.first?.hits.first?.matchedRanges.isEmpty == false)
        }
        for query in ["\"", "*", "-", "AND OR NOT", "%", "_"] { _ = try await index.search(.init(text: query)) }
        #expect(try await index.search(.init(text: "NOT" )).isEmpty)
    }

    @Test func filtersMergesNamesAndDates() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = MeetingIndex(fileURL: root.appending(path: "search.sqlite"))
        let person = PersonID(), user = PersonID()
        var meeting = fixture()
        meeting.speakers = [.init(id: SpeakerID("r2"), label: "B", person: person, embeddings: [])]
        meeting.mergedSpeakers = [SpeakerID("r1"): SpeakerID("r2")]
        var remote = meeting.utterances[0]
        remote.speaker = SpeakerID("r1")
        meeting.utterances.append(remote)
        try await index.update(meeting, user: user)
        for id in [person, user] {
            let result = try await index.search(.init(people: [id]))
            #expect(result.map(\.id) == [meeting.id])
            #expect(result.first?.hits.isEmpty == true)
        }
        #expect(try await index.search(.init(people: [PersonID()])).isEmpty)
        let date = meeting.metadata.startedAt
        #expect(try await index.search(.init(dateRange: date...date)).count == 1)
        #expect(try await index.search(.init(dateRange: date.addingTimeInterval(1)...date.addingTimeInterval(60))).isEmpty)
        #expect(try await index.search(.init(text: "Putty 預算", names: [person: "Putty"])).count == 1)
        #expect(try await index.search(.init(text: "Renamed", names: [person: "Renamed"])).count == 1)
        #expect(try await index.search(.init(text: "Putty", names: [person: "Renamed"])).isEmpty)
    }

    @Test func rankingReplacementAndRemoval() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = MeetingIndex(fileURL: root.appending(path: "search.sqlite"))
        var titled = fixture(title: "預算", text: "舊資料", date: .distantPast)
        let spoken = fixture()
        try await index.rebuild(from: [spoken, titled])
        #expect(try await index.search(.init(text: "預算")).map(\.id) == [titled.id, spoken.id])
        #expect(try await index.search(.init()).map(\.id) == [spoken.id, titled.id])
        #expect(try await index.search(.init(text: "預算", limit: 1)).map(\.id) == [titled.id])
        titled.metadata.title = "Replacement"
        titled.utterances = []
        try await index.update(titled)
        #expect(try await index.search(.init(text: "舊資料")).isEmpty)
        #expect(try await index.search(.init(text: "預算")).map(\.id) == [spoken.id])
        try await index.remove(spoken.id)
        #expect(try await index.search(.init(text: "預算")).isEmpty)
    }

    @Test func sourceRowsSnippetsAndMentionRemoval() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = MeetingIndex(fileURL: root.appending(path: "search.sqlite"))
        var meeting = fixture(text: String(repeating: "前", count: 60) + "預算決議")
        let sources = [UtteranceID("u1")]
        meeting.outputs.cleaned = .init(paragraphs: [.init(speaker: .me, text: "{{speaker:r2}}預算", sources: sources)])
        meeting.outputs.summary = .init(headline: "預算", decisions: [.init(text: "預算", sources: sources)],
            discussionPoints: [.init(text: "預算", sources: sources)], actionItems: [.init(text: "預算", owner: .me, sources: sources)])
        try await index.update(meeting)
        let result = try #require(try await index.search(.init(text: "預算")).first)
        #expect(result.totalHits == 6)
        #expect(result.hits.count == 3)
        #expect(result.hits.allSatisfy { [.headline, .decision, .discussion, .action].contains($0.kind) })
        #expect(result.hits.filter { $0.kind != .headline }.allSatisfy { $0.utterance == sources[0] && $0.time == 10 })
        #expect(try await index.search(.init(text: "speaker")).isEmpty)
        let snippet = try #require(try await index.search(.init(text: "決議")).first?.hits.first)
        #expect(snippet.snippet.hasPrefix("…"))
        #expect(snippet.matchedRanges.map { String(snippet.snippet[$0]) } == ["決議"])
    }

    @Test func corruptAndOldSchemaRebuiltFromLibrary() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MeetingLibrary(root: root.appending(path: "Meetings"))
        let meeting = fixture()
        try await library.save(meeting)
        for oldSchema in [false, true] {
            let file = root.appending(path: oldSchema ? "old.sqlite" : "corrupt.sqlite")
            if oldSchema {
                var db: OpaquePointer?
                #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
                #expect(sqlite3_exec(db, "CREATE TABLE obsolete (id TEXT); PRAGMA user_version=0", nil, nil, nil) == SQLITE_OK)
                sqlite3_close(db)
            } else { try Data("not a database".utf8).write(to: file) }
            let index = MeetingIndex(fileURL: file)
            try await index.reconcile(from: library.indexRecords())
            #expect(try await index.search(.init(text: "預算")).map(\.id) == [meeting.id])
        }
    }

    @Test func observerReportsOnlySuccessfulMutations() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MeetingLibrary(root: root.appending(path: "Meetings"))
        let (stream, continuation) = AsyncStream<MeetingID>.makeStream()
        await library.observe { continuation.yield($0) }
        let mic = root.appending(path: "mic.wav"), remote = root.appending(path: "remote.wav")
        try Data().write(to: mic)
        try Data().write(to: remote)
        let meeting = try await library.create(.init(micTrack: mic, remoteTrack: remote, highlights: [],
            metadata: .init(title: "Observed", startedAt: Date(), duration: 10)))
        try await library.save(meeting)
        let track = TrackTranscript(source: .cloud, content: .unlabeled([]))
        _ = try await library.attach(.init(me: track, remote: track), to: meeting.id)
        _ = try await library.attach(.init(me: track, remote: track), to: meeting.id)
        try await library.delete(meeting.id)
        await #expect(throws: LibraryError.self) { try await library.delete(meeting.id) }
        continuation.finish()
        var events: [MeetingID] = []
        for await event in stream { events.append(event) }
        #expect(events == Array(repeating: meeting.id, count: 4))
    }

    @Test func cancelledQueryDoesNotDamageIndex() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = MeetingIndex(fileURL: root.appending(path: "search.sqlite"))
        try await index.update(fixture())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await index.search(.init(text: "預算"))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await index.search(.init(text: "預算")).count == 1)
    }

    @Test func reconciliationRepairsMissedChanges() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MeetingLibrary(root: root.appending(path: "Meetings"))
        let index = MeetingIndex(fileURL: root.appending(path: "search.sqlite"))
        var meeting = fixture()
        try await library.save(meeting)
        try await index.reconcile(from: library.indexRecords())
        meeting.metadata.title = "Updated"
        try await library.save(meeting)
        try await index.reconcile(from: library.indexRecords())
        #expect(try await index.search(.init(text: "Updated")).count == 1)
        try await library.delete(meeting.id)
        try await index.reconcile(from: library.indexRecords())
        #expect(try await index.search(.init()).isEmpty)
    }
}
