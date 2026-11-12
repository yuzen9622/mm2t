import AppKit
import MM2TApp
import MM2TCore
import SwiftUI

/// The dashboard: the calendar first, then what the user owes, then what their meetings add up to.
struct HomeView: View {
    let app: AppController
    let open: (MeetingID) -> Void
    /// Numbers, bars and the heatmap start empty and run up to their values once the data is in.
    @State private var revealed = false

    private var model: DashboardModel { app.dashboard }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                PillButton("Start Recording", icon: "microphone", kind: .primary) {
                    Task { await app.capture.startNow(title: String(localized: "Recording")) }
                }
                .disabled(app.capture.state != .idle)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    CalendarCard(model: model)
                    HStack(alignment: .top, spacing: 14) {
                        // Equal halves: both cards stretch, so neither takes the other's room.
                        TodoCard(model: model, open: open)
                            .frame(maxWidth: .infinity)
                        MeetingsCard(stats: model.stats, days: model.activity, revealed: revealed)
                            .frame(maxWidth: .infinity)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 14) {
                        VoicesCard(voices: model.voices, revealed: revealed)
                        TermsCard(terms: model.terms, revealed: revealed)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .task(id: app.queue.revision) {
            await model.reload()
            revealed = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.reloadCalendar() }
        }
    }
}

/// A titled card of the dashboard. Cards side by side in a row stretch to the same height.
private struct DashCard<Content: View, Trailing: View>: View {
    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Icon(icon, size: 15).foregroundStyle(Palette.orange)
                Text(title).font(Typo.captionStrong).foregroundStyle(Palette.secondary)
                Spacer(minLength: 6)
                trailing
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

extension DashCard where Trailing == EmptyView {
    init(title: LocalizedStringKey, icon: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, icon: icon, trailing: { EmptyView() }, content: content)
    }
}

private struct Hint: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text).font(Typo.caption).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
    }
}

/// Plays `animation` once `revealed` turns on; under Reduce Motion the content just fades in.
struct Reveal: ViewModifier {
    let revealed: Bool
    var delay: Double = 0
    var offset: CGFloat = 0
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .scaleEffect(revealed || reduce ? 1 : scale)
            .offset(y: revealed || reduce ? 0 : offset)
            .motion(Motion.reveal.delay(delay), value: revealed)
    }
}

// MARK: Calendar

/// A month you can page through beside the agenda of the selected day, fed by every connected source.
struct CalendarCard: View {
    let model: DashboardModel
    @State private var width: CGFloat = 0
    @State private var forward = true
    @State private var showSources = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    static let rowHeight: CGFloat = 34
    private static let gridHeight: CGFloat = 18 + 6 + rowHeight * 6

    private var gridWidth: CGFloat { min(max(width * 0.42, 252), 360) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 18) {
                ZStack {
                    MonthGridView(model: model)
                        .id(model.month)
                        .transition(reduce ? .opacity : .push(from: forward ? .trailing : .leading))
                }
                .frame(width: gridWidth, height: Self.gridHeight, alignment: .top)
                .clipped()
                .motion(Motion.page, value: model.month)
                Rectangle().fill(Palette.border).frame(width: 1, height: Self.gridHeight)
                Group {
                    if model.hasConnectedCalendar {
                        DayAgenda(model: model)
                    } else {
                        ConnectCalendars(model: model)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: Self.gridHeight, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(model.month, format: .dateTime.year().month(.wide))
                .font(Typo.heading)
                .contentTransition(.numericText())
                .motion(Motion.select, value: model.month)
                .padding(.trailing, 6)
            IconButton("Previous Month", icon: "chevron-left") { page(-1) }
            IconButton("Next Month", icon: "chevron-right") { page(1) }
            if !Calendar.current.isDate(model.selectedDay, inSameDayAs: Date())
                || !Calendar.current.isDate(model.month, equalTo: Date(), toGranularity: .month) {
                PillButton("Today") {
                    forward = model.month < Date()
                    Task { await model.showToday() }
                }
                .padding(.leading, 4)
                .entrance(from: .leading, distance: 6)
            }
            Spacer(minLength: 8)
            if model.isLoadingCalendar {
                ProgressView().controlSize(.small).padding(.trailing, 6).transition(.opacity)
            }
            if model.hasConnectedCalendar {
                SourcesButton(sources: model.calendarSources) { showSources = true }
                    .popover(isPresented: $showSources, arrowEdge: .bottom) {
                        CalendarSourceList(model: model).frame(width: 308).padding(16)
                    }
            }
        }
        .motion(Motion.reveal, value: model.isLoadingCalendar)
        .motion(Motion.reveal, value: model.hasConnectedCalendar)
    }

    private func page(_ offset: Int) {
        forward = offset > 0
        Task { await model.showMonth(offset) }
    }
}

private struct MonthGridView: View {
    let model: DashboardModel
    @Namespace private var space

    private var weekdays: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    var body: some View {
        let days = model.gridDays
        let today = Calendar.current.startOfDay(for: Date())
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                    Text(verbatim: symbol).font(Typo.captionStrong).foregroundStyle(Palette.muted).frame(maxWidth: .infinity)
                }
            }
            .frame(height: 18)
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(days[(row * 7)..<min(row * 7 + 7, days.count)], id: \.self) { day in
                            DayCell(
                                day: day,
                                inMonth: Calendar.current.isDate(day, equalTo: model.month, toGranularity: .month),
                                isToday: day == today, isSelected: day == model.selectedDay,
                                count: model.events(on: day).count, space: space) { model.select(day) }
                        }
                    }
                }
            }
        }
        .motion(Motion.select, value: model.selectedDay)
    }
}

private struct DayCell: View {
    let day: Date
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let count: Int
    let space: Namespace.ID
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(spacing: 3) {
                Text(verbatim: "\(Calendar.current.component(.day, from: day))")
                    .font(.system(size: 13, weight: isToday || isSelected ? .semibold : .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? .white : isToday ? Palette.orange : inMonth ? Palette.text : Palette.muted)
                    .frame(width: 26, height: 26)
                    .background {
                        if isSelected {
                            Circle().fill(Palette.orange).matchedGeometryEffect(id: "selection", in: space)
                        } else if isToday {
                            Circle().fill(Palette.orangeSoft)
                        } else if hovering {
                            Circle().fill(Palette.hover)
                        }
                    }
                HStack(spacing: 2) {
                    ForEach(0..<min(count, 3), id: \.self) { _ in
                        Circle().fill(inMonth ? Palette.orange : Palette.muted).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: CalendarCard.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
        .accessibilityLabel(Text(day, format: .dateTime.month().day().weekday(.wide)))
        .accessibilityValue(count > 0 ? Text("^[\(count) event](inflect: true)") : Text(verbatim: ""))
    }
}

/// The selected day's events: time, title, source and a Join button where there is a call link.
private struct DayAgenda: View {
    let model: DashboardModel

    var body: some View {
        let day = model.selectedDay
        let events = model.events(on: day)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(day, format: .dateTime.month(.abbreviated).day().weekday(.wide)).font(Typo.bodyStrong)
                if let relative = relative(day) {
                    Text(relative).font(Typo.captionStrong).foregroundStyle(Palette.orange)
                }
                Spacer(minLength: 0)
                if !events.isEmpty {
                    Text("^[\(events.count) event](inflect: true)").font(Typo.caption).foregroundStyle(Palette.secondary).monospacedDigit()
                }
            }
            if events.isEmpty {
                VStack(spacing: 8) {
                    Icon("calendar-event", size: 22).foregroundStyle(Palette.muted)
                    Text(model.isLoadingCalendar ? "Loading your calendar…" : "Nothing scheduled.")
                        .font(Typo.caption).foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else {
                ScrollView {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(events) { EventRow(event: $0, now: context.date) }
                        }
                    }
                }
                .scrollIndicators(.never)
                .id(day)
                .transition(.opacity)
            }
        }
        .motion(Motion.select, value: day)
        .motion(Motion.reveal, value: events.map(\.id))
    }

    private func relative(_ day: Date) -> LocalizedStringKey? {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInTomorrow(day) { return "Tomorrow" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return nil
    }
}

private struct EventRow: View {
    let event: CalendarEvent
    let now: Date
    @State private var hovering = false

    private var isLive: Bool { !event.isAllDay && event.start <= now && event.end > now }
    /// Starting within ten minutes counts as live for the Join button.
    private var isSoon: Bool { !event.isAllDay && event.start > now && event.start.timeIntervalSince(now) < 600 }
    private var isPast: Bool { event.end <= now }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                if event.isAllDay {
                    Text("All day").font(Typo.captionStrong)
                } else {
                    Text(event.start, format: .dateTime.hour().minute()).font(Typo.captionStrong)
                    Text(event.end, format: .dateTime.hour().minute()).font(Typo.caption).foregroundStyle(Palette.muted)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 64, alignment: .trailing)
            Capsule()
                .fill(isLive || isSoon ? Palette.orange : isPast ? Palette.field : Palette.orange.opacity(0.35))
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: event.title.isEmpty ? "–" : event.title).font(Typo.bodyStrong).lineLimit(1)
                    .foregroundStyle(isPast ? Palette.secondary : Palette.text)
                HStack(spacing: 4) {
                    Icon(SourceGlyph.icon(event.source), size: 12)
                    Text(verbatim: [Copy.calendarSource(event.source), event.calendar].filter { !$0.isEmpty }.joined(separator: " · "))
                        .lineLimit(1)
                    if isLive { Text("· Now").foregroundStyle(Palette.orange).fixedSize() }
                }
                .font(Typo.caption)
                .foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 6)
            if let link = event.link, !isPast {
                PillButton("Join", icon: "video", kind: isLive || isSoon ? .primary : .ghost) { NSWorkspace.shared.open(link) }
                    .fixedSize()
                    .help(link.absoluteString)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
    }
}

/// A source's icon, for agenda rows and the sources button.
enum SourceGlyph {
    static func icon(_ kind: CalendarSourceKind) -> String {
        switch kind {
        case .apple: "brand-apple"
        case .google: "brand-google"
        case .microsoft: "brand-office"
        }
    }
}

/// The connected sources as small overlapping badges, opening the list of all sources.
private struct SourcesButton: View {
    let sources: [CalendarSourceState]
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                HStack(spacing: -5) {
                    ForEach(sources.filter { $0.connection == .connected }) { source in
                        Icon(SourceGlyph.icon(source.kind), size: 11)
                            .frame(width: 20, height: 20)
                            .background(Palette.field, in: Circle())
                            .overlay(Circle().strokeBorder(Palette.card, lineWidth: 1.5))
                    }
                }
                Text("Calendars").font(Typo.captionStrong)
                if sources.contains(where: { $0.problem != nil }) {
                    Circle().fill(Palette.danger).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(Palette.text)
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: 30)
            .background(hovering ? Palette.hover : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.border))
            .contentShape(Capsule())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
    }
}

/// Shown in place of the agenda until a source is connected: the three sources to choose from.
private struct ConnectCalendars: View {
    let model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bring in your calendar").font(Typo.bodyStrong)
            Text("See each day's meetings here and join calls in one click. Connect as many as you use.")
                .font(Typo.caption).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            CalendarSourceList(model: model)
        }
    }
}

/// Every calendar source with its state and the one action it allows. Used on the dashboard and in Settings.
struct CalendarSourceList: View {
    let model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.calendarSources) { source in
                SourceRow(source: source, model: model)
            }
        }
        .motion(Motion.reveal, value: model.calendarSources)
    }
}

private struct SourceRow: View {
    let source: CalendarSourceState
    let model: DashboardModel

    private var unavailable: Bool { source.connection == .unavailable }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Icon(SourceGlyph.icon(source.kind), size: 16)
                .foregroundStyle(source.connection == .connected ? Palette.orange : unavailable ? Palette.muted : Palette.text)
                .frame(width: 32, height: 32)
                .background(source.connection == .connected ? Palette.orangeSoft : Palette.field, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: Copy.calendarSource(source.kind)).font(Typo.bodyStrong)
                        .foregroundStyle(unavailable ? Palette.secondary : Palette.text)
                    if source.connection == .connected {
                        Icon("check", size: 12).foregroundStyle(Palette.success)
                    }
                }
                Group {
                    if let problem = source.problem {
                        Text(verbatim: Copy.calendarProblem(problem, source.kind)).foregroundStyle(Palette.danger)
                    } else if unavailable || source.connection == .denied {
                        Text(verbatim: Copy.calendarUnavailable(source.kind)).foregroundStyle(Palette.muted)
                    } else {
                        Text(verbatim: Copy.calendarSourceDetail(source.kind)).foregroundStyle(Palette.secondary)
                    }
                }
                .font(Typo.caption)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action.fixedSize()
        }
    }

    @ViewBuilder private var action: some View {
        switch source.connection {
        case .unavailable:
            EmptyView()
        case .connecting:
            ProgressView().controlSize(.small).frame(width: 30)
        case .connected:
            PillButton("Disconnect") { Task { await model.disconnect(source.kind) } }
        case .disconnected:
            PillButton("Connect") { Task { await model.connect(source.kind) } }
        case .denied:
            PillButton("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            }
        }
    }
}

// MARK: To-dos

private struct TodoCard: View {
    let model: DashboardModel
    let open: (MeetingID) -> Void

    private var shown: [TodoRow] {
        Array((model.todos.filter { !$0.isDone } + model.todos.filter(\.isDone)).prefix(7))
    }

    var body: some View {
        let remaining = model.todos.filter { !$0.isDone }.count
        DashCard(title: "To-dos", icon: "circle-check") {
            if !model.todos.isEmpty {
                Text("\(remaining) open").font(Typo.caption).foregroundStyle(Palette.secondary).monospacedDigit()
                    .contentTransition(.numericText(value: Double(remaining)))
                    .motion(Motion.select, value: remaining)
            }
        } content: {
            if model.todos.isEmpty {
                Hint(text: "Action items from your meetings' summaries collect here.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(shown) { todo in TodoRowView(todo: todo, toggle: { model.toggle(todo) }, open: { open(todo.meeting) }) }
                }
                .motion(Motion.select, value: shown.map(\.id))
                let visible = shown.filter { !$0.isDone }.count
                if remaining > visible { Hint(text: "\(remaining - visible) more in your meetings") }
            }
        }
    }
}

private struct TodoRowView: View {
    let todo: TodoRow
    let toggle: () -> Void
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: toggle) {
                ZStack {
                    Circle().strokeBorder(todo.isDone ? Palette.orange : Palette.muted, lineWidth: 1.5)
                    if todo.isDone {
                        Circle().fill(Palette.orange)
                        Icon("check", size: 11).foregroundStyle(.white)
                    }
                }
                .frame(width: 18, height: 18)
                .contentShape(Circle())
            }
            .buttonStyle(Pressable())
            .accessibilityLabel(todo.isDone ? "Mark as not done" : "Mark as done")
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(todo.text)
                        .strikethrough(todo.isDone)
                        .foregroundStyle(todo.isDone ? Palette.muted : Palette.text)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: [todo.owner, todo.meetingTitle].compactMap { $0 }.joined(separator: " · "))
                        .font(Typo.caption)
                        .foregroundStyle(hovering ? Palette.orange : Palette.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
        .motion(Motion.touch, value: hovering)
        .motion(Motion.select, value: todo.isDone)
    }
}

// MARK: Meetings in numbers

/// What the user's meetings add up to: four figures over twelve weeks of days.
private struct MeetingsCard: View {
    let stats: DashboardStats
    let days: [ActivityDay]
    let revealed: Bool

    var body: some View {
        DashCard(title: "Your meetings", icon: "sparkles") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Figure(value: Double(revealed ? stats.meetings : 0), label: "Meetings recorded")
                    Figure(value: revealed ? stats.recorded / 3600 : 0, label: "Hours in meetings", decimals: 1)
                }
                GridRow {
                    Figure(value: Double(revealed ? stats.characters : 0), label: "Characters transcribed")
                    ShareFigure(share: stats.myShare.map { revealed ? $0 : 0 })
                }
            }
            Rectangle().fill(Palette.border).frame(height: 1).padding(.vertical, 2)
            let active = days.filter { $0.minutes > 0 }.count
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Last 12 weeks").font(Typo.captionStrong).foregroundStyle(Palette.secondary)
                Text(verbatim: "·").font(Typo.caption).foregroundStyle(Palette.muted)
                Text(verbatim: "\(revealed ? active : 0)")
                    .font(Typo.captionStrong).monospacedDigit()
                    .contentTransition(.numericText(value: Double(revealed ? active : 0)))
                    .motion(Motion.page, value: revealed)
                Text("days with meetings").font(Typo.caption).foregroundStyle(Palette.secondary)
                Spacer()
                Legend()
            }
            Heatmap(days: days, revealed: revealed)
        }
    }
}

private struct Figure: View {
    let value: Double
    let label: LocalizedStringKey
    var decimals = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number.precision(.fractionLength(decimals)))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: value))
                .motion(Motion.page, value: value)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label).font(Typo.caption).foregroundStyle(Palette.secondary).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The user's part of the talking, as a ring that draws itself.
private struct ShareFigure: View {
    let share: Double?

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Palette.field, lineWidth: 4)
                Circle().trim(from: 0, to: share ?? 0)
                    .stroke(Palette.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 26, height: 26)
            .motion(Motion.page, value: share)
            VStack(alignment: .leading, spacing: 2) {
                if let share {
                    Text(share, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: share))
                        .motion(Motion.page, value: share)
                } else {
                    Text(verbatim: "–").font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(Palette.muted)
                }
                Text("Your share of the talking").font(Typo.caption).foregroundStyle(Palette.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 3) {
            ForEach([0.0, 0.3, 0.6, 1.0], id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(level == 0 ? Palette.field : Palette.orange.opacity(0.25 + 0.75 * level))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Twelve weeks of days, one column per week, tinted by how long the user spent in meetings. The
/// weeks share the card's whole width; rows keep one height so the map stays a calendar strip.
private struct Heatmap: View {
    let days: [ActivityDay]
    let revealed: Bool

    private var weeks: [[ActivityDay?]] {
        guard let first = days.first else { return [] }
        let calendar = Calendar.current
        let lead = (calendar.component(.weekday, from: first.date) - calendar.firstWeekday + 7) % 7
        let padded = [ActivityDay?](repeating: nil, count: lead) + days.map(Optional.some)
        return stride(from: 0, to: padded.count, by: 7).map { Array(padded[$0..<min($0 + 7, padded.count)]) }
    }

    var body: some View {
        let peak = max(days.map(\.minutes).max() ?? 0, 1)
        HStack(alignment: .top, spacing: Self.gap) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { column, week in
                VStack(spacing: Self.gap) {
                    ForEach(0..<7, id: \.self) { row in
                        ActivityCell(day: row < week.count ? week[row] : nil, peak: peak)
                            .modifier(Reveal(revealed: revealed, delay: Double(column) * 0.025, scale: 0.4))
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    static let cell: CGFloat = 14
    static let gap: CGFloat = 4
}

private struct ActivityCell: View {
    let day: ActivityDay?
    let peak: Double
    @State private var hovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(fill)
            .frame(maxWidth: .infinity, minHeight: Heatmap.cell, maxHeight: Heatmap.cell)
            .onHover { hovering = $0 }
            .tip(verbatim: label, show: hovering && day != nil)
    }

    private var fill: Color {
        guard let day else { return .clear }
        return day.minutes > 0 ? Palette.orange.opacity(0.25 + 0.75 * day.minutes / peak) : Palette.field
    }

    private var label: String { day?.tipLabel ?? "" }
}

extension ActivityDay {
    /// The heatmap cell's tooltip: the date, and the time in meetings when there was any.
    var tipLabel: String {
        let date = date.formatted(.dateTime.month().day())
        let time = Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return minutes > 0 ? "\(date) · \(time)" : date
    }
}

// MARK: Voices and terms

private struct VoicesCard: View {
    let voices: [VoiceRow]
    let revealed: Bool

    var body: some View {
        DashCard(title: "Voices you hear most", icon: "users") {
            if voices.isEmpty {
                Hint(text: "Name the speakers in a meeting and mm2t starts recognizing their voices.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(voices) { voice in
                        HStack(spacing: 10) {
                            Avatar(name: voice.name, isNamed: true)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(verbatim: voice.name).font(Typo.bodyStrong).lineLimit(1)
                                    Spacer()
                                    Text("\(Duration.seconds(voice.seconds), format: .units(allowed: [.hours, .minutes], width: .abbreviated)) · ^[\(voice.meetings) meeting](inflect: true)")
                                        .font(Typo.caption).foregroundStyle(Palette.secondary).monospacedDigit()
                                }
                                ProgressLine(fraction: revealed ? voice.fraction : 0)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct TermsCard: View {
    let terms: [TermRow]
    let revealed: Bool

    var body: some View {
        DashCard(title: "Your words", icon: "book-2") {
            if terms.isEmpty {
                Hint(text: "Terms from your vocabulary appear here once they come up in meetings.")
            } else {
                WordCloud(terms: terms, revealed: revealed)
            }
        }
    }
}

/// Lays children out left to right, wrapping to the next line when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1] = (last.indices + [index], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}
