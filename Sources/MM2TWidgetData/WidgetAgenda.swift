import Foundation

/// What one widget size shows at one moment. Worked out from the snapshot for each timeline entry,
/// so a finished meeting drops off at its end time without the app running.
public struct WidgetAgenda: Equatable, Sendable {
    public enum Size: Sendable {
        case medium
        case large

        /// Today's rows: the medium size beside its date, the large one above tomorrow.
        var todayLimit: Int { self == .medium ? 3 : 4 }
        /// The large size shows six rows in all; tomorrow gets what today leaves.
        static let largeRows = 6
    }

    /// Today's meetings that have not ended, in start order.
    public let today: [WidgetSnapshot.Event]
    /// Today's meetings left out for room.
    public let moreToday: Int
    /// Tomorrow's meetings; nil when this size has no room for tomorrow or the snapshot does not
    /// reach that far, so an unknown day is never shown as a free one.
    public let tomorrow: [WidgetSnapshot.Event]?
    public let moreTomorrow: Int
    /// Only the large size shows the to-do count.
    public let openTodos: Int?
    public let recording: WidgetSnapshot.Recording?

    public init(_ snapshot: WidgetSnapshot, at now: Date, size: Size, calendar: Calendar = .current) {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let endOfTomorrow = calendar.date(byAdding: .day, value: 2, to: startOfToday) ?? now
        let remaining = snapshot.events.filter { $0.end > now && $0.start < startOfTomorrow }
        today = Array(remaining.prefix(size.todayLimit))
        moreToday = remaining.count - today.count
        if size == .large, snapshot.through >= endOfTomorrow {
            let all = snapshot.events.filter { $0.start >= startOfTomorrow && $0.start < endOfTomorrow }
            let shown = Array(all.prefix(Size.largeRows - today.count))
            tomorrow = shown
            moreTomorrow = all.count - shown.count
        } else {
            tomorrow = nil
            moreTomorrow = 0
        }
        openTodos = size == .large ? snapshot.openTodos : nil
        recording = snapshot.recording
    }

    /// Starting within this long counts as live for the Join control, as on the app's home screen.
    public static let soon: TimeInterval = 600

    /// The moments the widget has to redraw without being told: when each event turns live, starts
    /// and ends, and the next two midnights, when today and tomorrow move on.
    public static func boundaries(of snapshot: WidgetSnapshot, after now: Date, calendar: Calendar = .current) -> [Date] {
        let midnights = (1...2).compactMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: now)) }
        let moments = snapshot.events.flatMap { [$0.start.addingTimeInterval(-soon), $0.start, $0.end] }
        return Set(moments + midnights).filter { $0 > now }.sorted()
    }

    public static func isLive(_ event: WidgetSnapshot.Event, at now: Date) -> Bool {
        event.start.timeIntervalSince(now) < soon && event.end > now
    }
}
