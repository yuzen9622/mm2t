import Foundation
import MM2TCore
import Testing
@testable import MM2TApp

@MainActor @Suite struct SearchPaletteTests {
    @Test func currentFolderOutranksMoreRecentHitsBeforeLimit() async throws {
        let world = try World(), folders = world.app.folders
        let folder = try #require(folders.create("驗收"))
        var ids: [MeetingID] = []
        for n in 0..<7 {
            var meeting = try await world.recordedMeeting(title: "專案會議 \(n)")
            meeting.metadata.startedAt = Date(timeIntervalSince1970: Double(n)); try await world.library.save(meeting); ids.append(meeting.id)
        }
        folders.move([ids[0]: folder], origin: .manual); folders.selected = folder
        try await world.app.searchIndex.rebuild(from: world.library.list())
        let model = SearchPaletteModel(index: world.app.searchIndex, voiceprints: world.app.voiceprints); model.folders = folders
        await model.open(); #expect(model.rows.first?.id == .meeting(ids[0]))
        model.query = "專案"; await model.refresh(); #expect(model.rows.first?.id == .meeting(ids[0]))
        folders.selected = nil; await model.refresh(); #expect(model.rows.first?.id == .meeting(ids[6]))
        #expect(model.rows.contains { $0.id == .meeting(ids[0]) })
    }

    @Test func recentMeetingsPeopleAndWrapping() async throws {
        let world = try World()
        for number in 0..<7 {
            var meeting = try await world.recordedMeeting(title: "Meeting \(number)")
            meeting.metadata.startedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(number * 60))
            try await world.library.save(meeting)
        }
        for number in 0..<7 { try await world.app.voiceprints.addPerson(name: "Person \(number)") }
        try await world.app.voiceprints.addPerson(name: "   ")
        try await world.app.searchIndex.rebuild(from: world.library.list())
        let model = SearchPaletteModel(index: world.app.searchIndex, voiceprints: world.app.voiceprints)
        await model.open()
        #expect(model.rows.count == 10)
        #expect(model.selection == model.rows.first?.id)
        #expect(model.ask == nil)
        model.move(-1)
        #expect(model.selection == model.rows.last?.id)
        model.move(1)
        #expect(model.selection == model.rows.first?.id)
        let destination = try #require(model.activate())
        #expect(destination.utterance == nil)
        #expect(destination.meeting == (try await world.library.list()).first?.id)
        let personRow = try #require(model.rows.first { if case .person = $0.content { true } else { false } })
        #expect(model.activate(personRow.id) == nil)
        #expect(model.person != nil)
        #expect(model.picker == nil)
        await model.refresh()
        #expect(model.rows.isEmpty)
        #expect(model.selection == nil)
        #expect(model.activate() == nil)
    }

    @Test func flattensGroupsAndReturnOpensHitSourceOrMeeting() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting(title: "預算會議")
        try await world.app.searchIndex.rebuild(from: [meeting])
        let model = SearchPaletteModel(index: world.app.searchIndex, voiceprints: world.app.voiceprints)
        await model.open()
        model.query = "那就這樣"
        await model.refresh()
        #expect(model.rows.count >= 2)
        let first = try #require(model.rows.first)
        #expect(first.id == .meeting(meeting.id))
        model.move(1)
        let destination = try #require(model.activate())
        #expect(destination.meeting == meeting.id)
        #expect(destination.utterance == meeting.utterances.first { $0.text.contains("那就這樣") }?.id)
        model.query = "預算"
        await model.refresh()
        let more = try #require(model.rows.first { if case .more = $0.content { true } else { false } })
        model.select(more.id)
        #expect(model.activate()?.meeting == meeting.id)
        #expect(model.activate()?.utterance == nil)
        model.move(1)
        #expect(model.selection == .ask)
        model.move(1)
        #expect(model.selection == model.rows.first?.id)
        model.query = "unmatched"
        #expect(model.selection == model.rows.first?.id)
        #expect(!model.rows.isEmpty, "previous results remain during debounce")
        await model.refresh()
        #expect(model.rows.map(\.id) == [.ask])
        var asked: String?
        model.ask = { asked = $0 }
        model.move(1)
        #expect(model.selection == .ask)
        #expect(model.activate() == nil)
        #expect(asked == "unmatched")
    }

    @Test func personAndDatePickersAreKeyboardNavigable() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        try await world.app.voiceprints.enrollUser(name: "Putty", embeddings: [])
        let user = try #require(await world.app.voiceprints.user())
        try await world.app.searchIndex.rebuild(from: [meeting], user: user.id)
        let model = SearchPaletteModel(index: world.app.searchIndex, voiceprints: world.app.voiceprints,
                                       now: { meeting.metadata.startedAt.addingTimeInterval(60) })
        await model.open()
        model.show(.people)
        #expect(model.rows.count == 1)
        #expect(model.selection == .person(user.id))
        #expect(model.activate() == nil)
        #expect(model.person == user.id)
        await model.refresh()
        #expect(model.rows.first?.id == .meeting(meeting.id))
        model.show(.dates)
        #expect(model.rows.count == 5)
        model.move(-1)
        #expect(model.selection == .date(.thisYear))
        model.move(1)
        #expect(model.selection == .date(.today))
        #expect(model.activate() == nil)
        #expect(model.date == .today)
        #expect(model.picker == nil)
        await model.refresh()
        #expect(model.rows.first?.id == .meeting(meeting.id))
        model.person = nil
        model.date = nil
        await model.refresh()
        #expect(model.isRecent)
    }

    @Test func debounceKeepsLatestQueryAndCloseCancelsIt() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting(title: "Unique planning")
        try await world.app.searchIndex.rebuild(from: [meeting])
        let model = SearchPaletteModel(index: world.app.searchIndex, voiceprints: world.app.voiceprints)
        await model.open()
        model.query = "absent"
        model.query = "Unique"
        #expect(await eventually { model.rows.count > 1 })
        #expect(model.rows.first?.id == .meeting(meeting.id))
        let prior = model.rows
        model.query = "absent"
        model.close()
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.rows == prior)
        await model.open()
        #expect(model.query.isEmpty)
        #expect(model.date == nil && model.person == nil && model.picker == nil)
        #expect(model.selection == model.rows.first?.id)
    }

    @Test func resolvesRenamedPeopleAtQueryTime() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        try await world.app.voiceprints.enrollUser(name: "Putty", embeddings: [])
        let user = try #require(await world.app.voiceprints.user())
        try await world.app.searchIndex.rebuild(from: [meeting], user: user.id)
        let model = SearchPaletteModel(index: world.app.searchIndex, voiceprints: world.app.voiceprints)
        await model.open()
        try await world.app.voiceprints.rename(user.id, to: "Renamed")
        model.query = "Renamed"
        await model.refresh()
        #expect(model.rows.first?.id == .meeting(meeting.id))
        #expect(model.names[user.id] == "Renamed")
        model.query = "Putty"
        await model.refresh()
        #expect(model.rows.map(\.id) == [.ask])
    }

    @Test func dateRangesUseCalendarDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12))!
        let expected: [(SearchPaletteModel.DateFilter, DateComponents)] = [
            (.today, DateComponents(year: 2026, month: 11, day: 15)),
            (.last7Days, DateComponents(year: 2026, month: 11, day: 9)),
            (.last30Days, DateComponents(year: 2026, month: 10, day: 17)),
            (.last3Months, DateComponents(year: 2026, month: 8, day: 15)),
            (.thisYear, DateComponents(year: 2026, month: 1, day: 1)),
        ]
        for (filter, components) in expected {
            let range = filter.range(now: now, calendar: calendar)
            #expect(range.lowerBound == calendar.date(from: components))
            #expect(range.upperBound == now)
        }
    }
}

@MainActor @Suite struct SearchIndexSyncTests {
    @Test func observesCreateSaveAttachAndDeleteWithoutBlockingLibrary() async throws {
        let world = try World()
        let sync = SearchIndexSync(library: world.library, index: world.app.searchIndex, voiceprints: world.app.voiceprints)
        await sync.start()
        let mic = world.root.appending(path: "observer-mic.wav")
        let remote = world.root.appending(path: "observer-remote.wav")
        try Data().write(to: mic)
        try Data().write(to: remote)
        var meeting = try await world.library.create(.init(micTrack: mic, remoteTrack: remote, highlights: [],
            metadata: .init(title: "Observer", startedAt: Date(), duration: 20)))
        #expect(try await waitForIndex(world.app.searchIndex, query: "Observer", count: 1))
        meeting.metadata.title = "Replacement"
        try await world.library.save(meeting)
        #expect(try await waitForIndex(world.app.searchIndex, query: "Replacement", count: 1))
        let record = try #require(try await world.library.indexRecord(meeting.id))
        #expect(record.meeting.metadata.title == "Replacement")
        let track = TrackTranscript(source: .cloud, content: .unlabeled([]))
        _ = try await world.library.attach(.init(me: track, remote: track), to: meeting.id)
        #expect(try await waitForIndex(world.app.searchIndex, query: "Replacement", count: 1))
        try await world.library.delete(meeting.id)
        #expect(try await waitForIndex(world.app.searchIndex, query: "Replacement", count: 0))
    }

    @Test func unavailableIndexDoesNotPreventSavingAndCanBeReconciled() async throws {
        let world = try World()
        let blocked = world.root.appending(path: "blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let index = MeetingIndex(fileURL: blocked.appending(path: "search.sqlite"))
        let sync = SearchIndexSync(library: world.library, index: index, voiceprints: world.app.voiceprints)
        await sync.start()
        let meeting = try await world.recordedMeeting(title: "Saved despite index failure")
        #expect(try await world.library.meeting(meeting.id).status == .completed)
        let model = SearchPaletteModel(index: index, voiceprints: world.app.voiceprints)
        await model.open()
        #expect(model.failed)
        #expect(model.rows.isEmpty && model.selection == nil)
        #expect(model.activate() == nil)
        try FileManager.default.removeItem(at: blocked)
        try await index.reconcile(from: world.library.indexRecords())
        await model.refresh()
        #expect(!model.failed)
        #expect(model.activate()?.meeting == meeting.id)
    }

    private func waitForIndex(_ index: MeetingIndex, query: String, count: Int) async throws -> Bool {
        for _ in 0..<500 {
            if try await index.search(.init(text: query)).count == count { return true }
            try await Task.sleep(for: .milliseconds(2))
        }
        return false
    }
}
