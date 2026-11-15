import AppKit
import Foundation
import MM2TWidgetData
import Observation
import WidgetKit

/// Keeps the desktop widget's snapshot in step with the dashboard's calendar and to-dos and with
/// the recording, and opens the call a widget's Join click asks for. The widget only reads the
/// snapshot; the calendars are read here, through the same sources as the home screen.
@MainActor
public final class WidgetPublisher {
    /// How often the calendar is read again while the app runs, so meetings added elsewhere reach
    /// the widget even when no window is open.
    static let refreshInterval = Duration.seconds(15 * 60)

    private let file: URL
    private let dashboard: DashboardModel
    private let capture: CaptureController
    private let now: () -> Date
    private var last: WidgetSnapshot?
    private var refresh: Task<Void, Never>?

    init(file: URL, dashboard: DashboardModel, capture: CaptureController, now: @escaping () -> Date) {
        self.file = file
        self.dashboard = dashboard
        self.capture = capture
        self.now = now
    }

    func start() {
        guard refresh == nil else { return }
        last = (try? Data(contentsOf: file)).flatMap(WidgetSnapshot.decode)
        observe()
        refresh = Task { [weak self] in
            await self?.dashboard.reload()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                await self?.dashboard.reloadCalendar()
                // Also moves the covered days on after midnight when nothing else changed.
                self?.publish()
            }
        }
    }

    /// Opens the call a widget Join link names. The link carries only an event id; the address is
    /// the one this app wrote into the snapshot, so nothing else can make the app open a URL.
    @discardableResult
    public func open(_ url: URL) -> Bool {
        guard let snapshot = last ?? (try? Data(contentsOf: file)).flatMap(WidgetSnapshot.decode),
              let meeting = WidgetLink.meetingURL(for: url, in: snapshot) else { return false }
        return NSWorkspace.shared.open(meeting)
    }

    /// Publishes now and again whenever the calendar, the to-dos or the recording state changes.
    /// The meters are read without being observed, so their 20 updates a second write nothing.
    private func observe() {
        withObservationTracking {
            _ = (dashboard.monthEvents, dashboard.gridDays, dashboard.todos, capture.state)
        } onChange: {
            Task { @MainActor [weak self] in self?.observe() }
        }
        publish()
    }

    private func publish() {
        let date = now()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        // The events are those of the month on screen; when the user has moved to another month
        // they say nothing about today, and the last snapshot's events stay.
        let covered = [0, 1].allSatisfy { offset in
            calendar.date(byAdding: .day, value: offset, to: today).map(dashboard.gridDays.contains) ?? false
        }
        let snapshot = Self.snapshot(
            events: covered ? dashboard.monthEvents : nil, openTodos: dashboard.todos.count { !$0.isDone },
            state: capture.state, elapsed: capture.meters.elapsed, previous: last, now: date, calendar: calendar)
        guard snapshot != last else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try snapshot.encoded().write(to: file, options: .atomic)
            last = snapshot
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetLink.kind)
        } catch {
            // Left for the next change to retry; the widget keeps showing the last good file.
        }
    }

    /// `events` nil keeps the previous snapshot's events. Only timed events of today and tomorrow
    /// that have not ended go in: all that the widget shows, and no more of the calendar than that.
    static func snapshot(events: [CalendarEvent]?, openTodos: Int, state: CaptureState, elapsed: TimeInterval,
                         previous: WidgetSnapshot?, now: Date, calendar: Calendar) -> WidgetSnapshot {
        let recording: WidgetSnapshot.Recording? = switch state {
        // Whole seconds, so a snapshot rewritten mid-recording for another reason compares equal.
        case .recording, .endingSoon: .running(since: Date(timeIntervalSince1970: (now.timeIntervalSince1970 - elapsed).rounded()))
        case .paused: .paused(elapsed: elapsed.rounded())
        default: nil
        }
        guard let events else {
            return WidgetSnapshot(events: previous?.events ?? [], through: previous?.through ?? now,
                                  openTodos: openTodos, recording: recording)
        }
        let start = calendar.startOfDay(for: now)
        let through = calendar.date(byAdding: .day, value: 2, to: start) ?? now
        let kept = events.filter { !$0.isAllDay && $0.start < through && $0.end > now }.map {
            WidgetSnapshot.Event(id: $0.id, title: $0.title, start: $0.start, end: $0.end, link: $0.link)
        }
        return WidgetSnapshot(events: kept, through: through, openTodos: openTodos, recording: recording)
    }
}
