import Foundation
import MM2TWidgetData
import Testing
@testable import MM2TApp

@MainActor @Suite struct DesktopWidgetTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }()

    private func at(_ hour: Int, day: Int = 15) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    private func event(_ id: String, _ start: Date, allDay: Bool = false, hours: Double = 1) -> CalendarEvent {
        CalendarEvent(id: id, title: id, start: start, end: start.addingTimeInterval(hours * 3600), isAllDay: allDay,
                      calendar: "Work", link: URL(string: "https://teams.microsoft.com/l/meetup-join/1"), source: .microsoft)
    }

    @Test func theSnapshotHoldsOnlyTimedMeetingsOfTodayAndTomorrowThatHaveNotEnded() {
        let events = [
            event("ended", at(8)), event("allDay", at(0), allDay: true, hours: 24), event("now", at(9, day: 15)),
            event("tomorrow", at(15, day: 16)), event("later", at(9, day: 17)),
        ]
        let snapshot = WidgetPublisher.snapshot(events: events, openTodos: 2, state: .idle, elapsed: 0, previous: nil,
                                                now: at(9).addingTimeInterval(600), calendar: calendar)
        #expect(snapshot.events.map(\.id) == ["now", "tomorrow"])
        #expect(snapshot.through == at(0, day: 17))
        #expect(snapshot.openTodos == 2)
        #expect(snapshot.recording == nil)
        #expect(snapshot.events.first?.link?.host() == "teams.microsoft.com")
    }

    @Test func withoutTodaysEventsTheLastSnapshotsStay() {
        let previous = WidgetPublisher.snapshot(events: [event("now", at(9))], openTodos: 0, state: .idle, elapsed: 0,
                                                previous: nil, now: at(8), calendar: calendar)
        let kept = WidgetPublisher.snapshot(events: nil, openTodos: 5, state: .idle, elapsed: 0, previous: previous,
                                            now: at(8), calendar: calendar)
        #expect(kept.events == previous.events && kept.through == previous.through)
        #expect(kept.openTodos == 5)
    }

    @Test func aRecordingIsShownWithItsStartSoTheWidgetClockRunsOnItsOwn() throws {
        let target = RecordingTarget(bundleID: "us.zoom.xos", name: "Zoom", platform: .zoom)
        let now = at(10).addingTimeInterval(0.4)
        let running = WidgetPublisher.snapshot(events: [], openTodos: 0, state: .recording(target), elapsed: 125.2,
                                               previous: nil, now: now, calendar: calendar)
        #expect(running.recording == .running(since: at(10).addingTimeInterval(-125)))
        let paused = WidgetPublisher.snapshot(events: [], openTodos: 0, state: .paused(target), elapsed: 125.2,
                                              previous: nil, now: now, calendar: calendar)
        #expect(paused.recording == .paused(elapsed: 125))
        let prompting = WidgetPublisher.snapshot(events: [], openTodos: 0, state: .starting(target), elapsed: 0,
                                                 previous: nil, now: now, calendar: calendar)
        #expect(prompting.recording == nil, "nothing is recorded before the recording has started")
    }
}
