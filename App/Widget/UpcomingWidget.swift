import MM2TWidgetData
import SwiftUI
import WidgetKit

@main
struct MM2TWidgets: WidgetBundle {
    var body: some Widget { UpcomingWidget() }
}

/// Today's remaining meetings with their Join links; the large size adds tomorrow and the open
/// to-dos. While mm2t records, it shows the recording instead.
struct UpcomingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetLink.kind, provider: Provider()) { entry in
            UpcomingView(entry: entry)
        }
        .configurationDisplayName("Upcoming Meetings")
        .description("Today’s remaining meetings, with a Join button for each call.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    /// Nil until the app has written one this widget can read.
    let snapshot: WidgetSnapshot?
}

/// Reads the app's snapshot and lays out one entry per meeting boundary, so the rows change on
/// time while the app is not running. The app asks for a new timeline whenever it rewrites the file.
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: .sample(at: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        let snapshot = Self.read()
        completion(Entry(date: .now, snapshot: snapshot ?? (context.isPreview ? .sample(at: .now) : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let now = Date.now
        guard let snapshot = Self.read() else {
            return completion(Timeline(entries: [Entry(date: now, snapshot: nil)], policy: .never))
        }
        let dates = [now] + WidgetAgenda.boundaries(of: snapshot, after: now)
        completion(Timeline(entries: dates.map { Entry(date: $0, snapshot: snapshot) }, policy: .atEnd))
    }

    private static func read() -> WidgetSnapshot? {
        WidgetLink.snapshotFile().flatMap { try? Data(contentsOf: $0) }.flatMap(WidgetSnapshot.decode)
    }
}

private extension WidgetSnapshot {
    /// What the widget gallery shows before the app has written anything.
    static func sample(at now: Date) -> WidgetSnapshot {
        let hour = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        let call = URL(string: "https://meet.google.com")
        return WidgetSnapshot(
            events: [
                Event(id: "sample-1", title: String(localized: "Weekly sync"), start: hour.addingTimeInterval(3600),
                      end: hour.addingTimeInterval(5400), link: call),
                Event(id: "sample-2", title: String(localized: "Design review"), start: hour.addingTimeInterval(7200),
                      end: hour.addingTimeInterval(9000), link: nil),
            ],
            through: now, openTodos: 2, recording: nil)
    }
}

// MARK: Views

struct UpcomingView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                let agenda = WidgetAgenda(snapshot, at: entry.date, size: family == .systemLarge ? .large : .medium)
                if let recording = agenda.recording {
                    RecordingView(recording: recording)
                } else if family == .systemLarge {
                    LargeAgenda(agenda: agenda, now: entry.date)
                } else {
                    MediumAgenda(agenda: agenda, now: entry.date)
                }
            } else {
                Notice(text: "Open mm2t to show your meetings here.")
            }
        }
        .containerBackground(for: .widget) { WidgetPalette.background }
    }
}

/// The date on the left like Apple's Calendar widget, today's meetings beside it.
private struct MediumAgenda: View {
    let agenda: WidgetAgenda
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(now, format: .dateTime.weekday(.wide))
                    .font(WidgetType.captionStrong).foregroundStyle(WidgetPalette.orange).widgetAccentable()
                Text(now, format: .dateTime.day())
                    .font(WidgetType.day).monospacedDigit()
                Spacer(minLength: 0)
                if agenda.moreToday > 0 { More(count: agenda.moreToday) }
            }
            .frame(width: 72, alignment: .leading)
            Rows(events: agenda.today, now: now, empty: "No more meetings today.")
        }
    }
}

private struct LargeAgenda: View {
    let agenda: WidgetAgenda
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(now, format: .dateTime.weekday(.wide).month(.abbreviated).day()).font(WidgetType.heading)
                Spacer(minLength: 8)
                if let todos = agenda.openTodos, todos > 0 {
                    Text("^[\(todos) open to-do](inflect: true)")
                        .font(WidgetType.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            DaySection(title: "Today", more: agenda.moreToday) {
                Rows(events: agenda.today, now: now, empty: "No more meetings today.")
            }
            if let tomorrow = agenda.tomorrow {
                DaySection(title: "Tomorrow", more: agenda.moreTomorrow) {
                    Rows(events: tomorrow, now: now, empty: "Nothing scheduled tomorrow.")
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct DaySection<Content: View>: View {
    let title: LocalizedStringKey
    let more: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(WidgetType.captionStrong).foregroundStyle(WidgetPalette.orange).widgetAccentable()
                Spacer(minLength: 8)
                if more > 0 { More(count: more) }
            }
            content
        }
    }
}

private struct Rows: View {
    let events: [WidgetSnapshot.Event]
    let now: Date
    let empty: LocalizedStringKey

    var body: some View {
        if events.isEmpty {
            Text(empty).font(WidgetType.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(events) { EventRow(event: $0, now: now) }
            }
        }
    }
}

/// Time under the title rather than in a column, so the title gets the width; rows are set apart
/// by space alone, as on the app's home screen.
private struct EventRow: View {
    let event: WidgetSnapshot.Event
    let now: Date

    private var isLive: Bool { WidgetAgenda.isLive(event, at: now) }

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(isLive ? WidgetPalette.orange : WidgetPalette.orange.opacity(0.35))
                .frame(width: 3, height: 28)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: event.title.isEmpty ? "–" : event.title).font(WidgetType.bodyStrong).lineLimit(1)
                HStack(spacing: 3) {
                    Text(event.start, format: .dateTime.hour().minute())
                    Text(verbatim: "–")
                    Text(event.end, format: .dateTime.hour().minute())
                }
                .font(WidgetType.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 4)
            if event.link != nil, event.end > now {
                JoinLink(event: event, isLive: isLive)
            }
        }
    }
}

/// Opens the app, which opens the call. Recording starts the usual way, from the prompt the app
/// shows once it sees the call.
private struct JoinLink: View {
    let event: WidgetSnapshot.Event
    let isLive: Bool
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let filled = isLive && renderingMode == .fullColor
        Link(destination: WidgetLink.join(event)) {
            Text("Join")
                .font(WidgetType.captionStrong)
                .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(filled ? AnyShapeStyle(WidgetPalette.orange) : AnyShapeStyle(.primary.opacity(isLive ? 0.16 : 0.08)),
                            in: Capsule())
        }
    }
}

private struct More: View {
    let count: Int

    var body: some View {
        Text("+\(count) more").font(WidgetType.caption).foregroundStyle(.secondary).monospacedDigit()
    }
}

/// The capsule's clock, ticking on its own: a timer text needs no timeline reloads.
private struct RecordingView: View {
    let recording: WidgetSnapshot.Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(WidgetPalette.orange).frame(width: 8, height: 8).widgetAccentable()
                switch recording {
                case .running: Text("Recording in progress")
                case .paused: Text("Paused")
                }
            }
            .font(WidgetType.captionStrong)
            Group {
                switch recording {
                case .running(let since): Text(since, style: .timer)
                case .paused(let elapsed): Text(Duration.seconds(elapsed), format: .time(pattern: .hourMinuteSecond))
                }
            }
            .font(WidgetType.clock).monospacedDigit()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Notice: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text).font(WidgetType.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Style

/// The app's palette (`App/MM2T/Design/Tokens.swift`), only the values the widget draws with:
/// the extension is a separate target and does not compile the app's design files. Text uses the
/// system's primary and secondary styles so it follows the desktop's tinted and dimmed modes.
enum WidgetPalette {
    static let background = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x26 / 255, green: 0x26 / 255, blue: 0x28 / 255, alpha: 1) : .white
    })
    static let orange = Color(.sRGB, red: 0xF0 / 255, green: 0x70 / 255, blue: 0x0F / 255)
}

/// The app's rounded type scale, a step smaller for the widget's tighter space.
enum WidgetType {
    static let day = Font.system(size: 30, weight: .semibold, design: .rounded)
    static let clock = Font.system(size: 34, weight: .semibold, design: .rounded)
    static let heading = Font.system(size: 15, weight: .semibold, design: .rounded)
    static let bodyStrong = Font.system(size: 13, weight: .medium, design: .rounded)
    static let caption = Font.system(size: 11, weight: .regular, design: .rounded)
    static let captionStrong = Font.system(size: 11, weight: .medium, design: .rounded)
}
