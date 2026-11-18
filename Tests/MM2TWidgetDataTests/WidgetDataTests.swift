import Foundation
import Testing
@testable import MM2TWidgetData

@Suite struct WidgetDataTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }

    /// 2026-11-15 at `hour`:`minute` in Taipei.
    private static func at(_ hour: Int, _ minute: Int = 0, day: Int = 15) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private static func event(_ id: String, _ start: Date, minutes: Double = 30, link: String? = "https://meet.google.com/abc-defg-hij") -> WidgetSnapshot.Event {
        WidgetSnapshot.Event(id: id, title: "Meeting \(id)", start: start, end: start.addingTimeInterval(minutes * 60),
                             link: link.flatMap(URL.init(string:)))
    }

    @Test func aSnapshotSurvivesTheFileAndAnotherVersionIsIgnored() throws {
        let snapshot = WidgetSnapshot(
            events: [Self.event("b", Self.at(14)), Self.event("a", Self.at(9), link: nil)],
            through: Self.at(0, day: 17), openTodos: 3, recording: .running(since: Self.at(8, 30)))
        #expect(snapshot.events.map(\.id) == ["a", "b"], "events are kept in start order")

        let decoded = try #require(WidgetSnapshot.decode(snapshot.encoded()))
        #expect(decoded == snapshot)
        let paused = WidgetSnapshot(events: [], through: Self.at(0, day: 17), openTodos: 0, recording: .paused(elapsed: 125))
        #expect(WidgetSnapshot.decode(try paused.encoded()) == paused)

        var future = snapshot
        future.version = WidgetSnapshot.currentVersion + 1
        #expect(WidgetSnapshot.decode(try future.encoded()) == nil, "a file from another version is not misread")
        #expect(WidgetSnapshot.decode(Data("{\"version\":1}".utf8)) == nil)
        #expect(WidgetSnapshot.decode(Data()) == nil)
    }

    @Test func onlyWebCallLinksAreKept() {
        #expect(Self.event("a", Self.at(9), link: "zoommtg://zoom.us/join?confno=1").link == nil)
        #expect(Self.event("b", Self.at(9), link: "file:///etc/passwd").link == nil)
        #expect(Self.event("c", Self.at(9), link: "https://zoom.us/j/1").link != nil)
    }

    @Test func mediumShowsTodaysRemainingMeetingsAndCountsTheRest() {
        let snapshot = WidgetSnapshot(
            events: [
                Self.event("done", Self.at(8)),
                Self.event("now", Self.at(9, 45)),
                Self.event("1", Self.at(11)), Self.event("2", Self.at(13)), Self.event("3", Self.at(15)),
                Self.event("tomorrow", Self.at(9, day: 16)),
            ],
            through: Self.at(0, day: 17), openTodos: 4, recording: nil)
        let agenda = WidgetAgenda(snapshot, at: Self.at(10), size: .medium, calendar: Self.calendar)
        #expect(agenda.today.map(\.id) == ["now", "1", "2"], "an ended meeting is gone; one under way stays")
        #expect(agenda.moreToday == 1)
        #expect(agenda.tomorrow == nil, "the medium size has no room for tomorrow")
        #expect(agenda.openTodos == nil)
    }

    @Test func largeFillsSixRowsAcrossTodayAndTomorrowAndShowsToDos() {
        let tomorrow = (0..<5).map { Self.event("t\($0)", Self.at(9 + $0, day: 16)) }
        let snapshot = WidgetSnapshot(
            events: [Self.event("1", Self.at(11)), Self.event("2", Self.at(13))] + tomorrow
                + [Self.event("later", Self.at(9, day: 17))],
            through: Self.at(0, day: 17), openTodos: 4, recording: nil)
        let agenda = WidgetAgenda(snapshot, at: Self.at(10), size: .large, calendar: Self.calendar)
        #expect(agenda.today.map(\.id) == ["1", "2"])
        #expect(agenda.tomorrow?.map(\.id) == ["t0", "t1", "t2", "t3"])
        #expect(agenda.moreTomorrow == 1, "the day after tomorrow is not counted")
        #expect(agenda.openTodos == 4)

        let busy = WidgetSnapshot(events: (0..<6).map { Self.event("d\($0)", Self.at(11 + $0)) } + tomorrow,
                                  through: Self.at(0, day: 17), openTodos: 0, recording: nil)
        let full = WidgetAgenda(busy, at: Self.at(10), size: .large, calendar: Self.calendar)
        #expect(full.today.count == 4 && full.moreToday == 2)
        #expect(full.tomorrow?.count == 2 && full.moreTomorrow == 3)
    }

    @Test func aDayTheSnapshotDoesNotReachIsNotShownAsFree() {
        // Written yesterday: it covers yesterday and today, so tomorrow is unknown.
        let snapshot = WidgetSnapshot(events: [Self.event("1", Self.at(11))], through: Self.at(0, day: 16),
                                      openTodos: 0, recording: nil)
        let agenda = WidgetAgenda(snapshot, at: Self.at(10), size: .large, calendar: Self.calendar)
        #expect(agenda.today.map(\.id) == ["1"])
        #expect(agenda.tomorrow == nil)
    }

    @Test func theTimelineRedrawsWhenAMeetingTurnsLiveStartsAndEndsAndAtMidnight() {
        let snapshot = WidgetSnapshot(events: [Self.event("done", Self.at(8)), Self.event("1", Self.at(11))],
                                      through: Self.at(0, day: 17), openTodos: 0, recording: nil)
        let dates = WidgetAgenda.boundaries(of: snapshot, after: Self.at(10), calendar: Self.calendar)
        #expect(dates == [Self.at(10, 50), Self.at(11), Self.at(11, 30), Self.at(0, day: 16), Self.at(0, day: 17)])
        #expect(WidgetAgenda.isLive(Self.event("1", Self.at(11)), at: Self.at(10, 51)))
        #expect(!WidgetAgenda.isLive(Self.event("1", Self.at(11)), at: Self.at(10, 49)))
        #expect(!WidgetAgenda.isLive(Self.event("1", Self.at(11)), at: Self.at(11, 30)))
    }

    @Test func aJoinLinkOpensOnlyTheCallTheSnapshotHolds() {
        let call = Self.event("apple:AB12/x?y=1&z", Self.at(11))
        let snapshot = WidgetSnapshot(events: [call, Self.event("nolink", Self.at(12), link: nil)],
                                      through: Self.at(0, day: 17), openTodos: 0, recording: nil)
        let link = WidgetLink.join(call)
        #expect(link.scheme == "mm2t")
        #expect(WidgetLink.meetingURL(for: link, in: snapshot) == call.link, "an id with URL characters round-trips")

        #expect(WidgetLink.meetingURL(for: WidgetLink.join(Self.event("nolink", Self.at(12), link: nil)), in: snapshot) == nil)
        #expect(WidgetLink.meetingURL(for: URL(string: "mm2t://join?event=unknown")!, in: snapshot) == nil)
        #expect(WidgetLink.meetingURL(for: URL(string: "mm2t://join?url=https://evil.example")!, in: snapshot) == nil)
        #expect(WidgetLink.meetingURL(for: URL(string: "mm2t://open?event=\(call.id)")!, in: snapshot) == nil)
        #expect(WidgetLink.meetingURL(for: URL(string: "https://join?event=x")!, in: snapshot) == nil)

        // A file edited by hand to hold another kind of address is still refused.
        let edited = Data("""
            {"events":[{"id":"x","title":"","start":0,"end":1,"link":"file:///etc/hosts"}],"openTodos":0,"through":2,"version":1}
            """.utf8)
        let tampered = try! #require(WidgetSnapshot.decode(edited))
        #expect(WidgetLink.meetingURL(for: URL(string: "mm2t://join?event=x")!, in: tampered) == nil)
    }

    @Test func theGroupIsTheTeamsMacOSStyleGroup() {
        #expect(WidgetLink.groupIdentifier(team: "4RMY49Z36V") == "4RMY49Z36V.dev.mm2t")
    }
}
