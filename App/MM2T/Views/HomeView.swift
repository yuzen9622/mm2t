import AppKit
import MM2TApp
import MM2TCore
import SwiftUI

/// The dashboard: what the user owes, what is on today's calendar, and what their meetings add up to.
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
                    StatTiles(stats: model.stats, revealed: revealed)
                    HStack(alignment: .top, spacing: 14) {
                        TodoCard(model: model, open: open)
                        CalendarCard(model: model)
                    }
                    ActivityCard(days: model.activity, revealed: revealed)
                    HStack(alignment: .top, spacing: 14) {
                        VoicesCard(voices: model.voices, revealed: revealed)
                        TermsCard(terms: model.terms, revealed: revealed)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .task(id: app.queue.revision) {
            await model.reload()
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85)) { revealed = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.reloadCalendar() }
        }
    }
}

/// A titled card of the dashboard.
private struct DashCard<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Icon(icon, size: 15).foregroundStyle(Palette.orange)
                Text(title).font(Typo.captionStrong).foregroundStyle(Palette.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }
}

private struct Hint: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text).font(Typo.caption).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Numbers

private struct StatTiles: View {
    let stats: DashboardStats
    let revealed: Bool

    var body: some View {
        HStack(spacing: 14) {
            StatTile(value: Double(revealed ? stats.meetings : 0), label: "Meetings recorded")
            StatTile(value: revealed ? stats.recorded / 3600 : 0, label: "Hours in meetings", decimals: 1)
            StatTile(value: Double(revealed ? stats.characters : 0), label: "Characters transcribed")
            ShareTile(share: stats.myShare.map { revealed ? $0 : 0 })
        }
    }
}

private struct StatTile: View {
    let value: Double
    let label: LocalizedStringKey
    var decimals = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value, format: .number.precision(.fractionLength(decimals)))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: value))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label).font(Typo.caption).foregroundStyle(Palette.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// The user's part of the talking, as a ring that draws itself.
private struct ShareTile: View {
    let share: Double?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Palette.field, lineWidth: 7)
                Circle().trim(from: 0, to: share ?? 0)
                    .stroke(Palette.orange, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 4) {
                if let share {
                    Text(share, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: share))
                } else {
                    Text(verbatim: "–").font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(Palette.muted)
                }
                Text("Your share of the talking").font(Typo.caption).foregroundStyle(Palette.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: To-dos

private struct TodoCard: View {
    let model: DashboardModel
    let open: (MeetingID) -> Void

    private var shown: [TodoRow] {
        Array((model.todos.filter { !$0.isDone } + model.todos.filter(\.isDone)).prefix(8))
    }

    var body: some View {
        DashCard(title: "To-dos", icon: "circle-check") {
            if model.todos.isEmpty {
                Hint(text: "Action items from your meetings' summaries collect here.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(shown) { todo in TodoRowView(todo: todo, toggle: { model.toggle(todo) }, open: { open(todo.meeting) }) }
                }
                .motion(Motion.select, value: shown.map(\.id))
                let open = model.todos.filter { !$0.isDone }.count
                if open > shown.count { Hint(text: "\(open - shown.count) more in your meetings") }
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

// MARK: Calendar

private struct CalendarCard: View {
    let model: DashboardModel

    var body: some View {
        DashCard(title: "Calendar", icon: "calendar-event") {
            switch model.calendarAccess {
            case .notDetermined:
                Hint(text: "See today's meetings here and open their call links. mm2t reads the calendars this Mac already syncs.")
                PillButton("Connect Calendar", icon: "calendar-event", kind: .primary) { Task { await model.connectCalendar() } }
            case .denied:
                Hint(text: "mm2t isn't allowed to read your calendars. Allow it in System Settings.")
                PillButton("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
            case .granted:
                if model.events.isEmpty {
                    Hint(text: "Nothing on your calendar today or tomorrow.")
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.events.prefix(6)) { EventRow(event: $0) }
                    }
                }
                Hint(text: "Add Google or Outlook calendars in System Settings › Internet Accounts.")
            }
        }
    }
}

private struct EventRow: View {
    let event: CalendarEvent

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: event.title).font(Typo.bodyStrong).lineLimit(1)
                Group {
                    if event.isAllDay {
                        Text("\(event.start, format: .dateTime.weekday(.abbreviated)) · All day")
                    } else {
                        Text("\(event.start, format: .dateTime.weekday(.abbreviated).hour().minute()) – \(event.end, format: .dateTime.hour().minute())")
                    }
                }
                .font(Typo.caption).foregroundStyle(Palette.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 6)
            if let link = event.link {
                PillButton("Join", icon: "video") { NSWorkspace.shared.open(link) }
            }
        }
    }
}

// MARK: Activity

/// Twelve weeks of days, one column per week, tinted by how long the user spent in meetings.
private struct ActivityCard: View {
    let days: [ActivityDay]
    let revealed: Bool

    private var weeks: [[ActivityDay?]] {
        guard let first = days.first else { return [] }
        let lead = Calendar.current.component(.weekday, from: first.date) - 1
        let padded = [ActivityDay?](repeating: nil, count: lead) + days.map(Optional.some)
        return stride(from: 0, to: padded.count, by: 7).map { Array(padded[$0..<min($0 + 7, padded.count)]) }
    }

    var body: some View {
        let peak = max(days.map(\.minutes).max() ?? 0, 1)
        DashCard(title: "Last 12 weeks", icon: "sparkles") {
            HStack(alignment: .top, spacing: 4) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { column, week in
                    VStack(spacing: 4) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            ActivityCell(day: day, peak: peak)
                                .opacity(revealed ? 1 : 0)
                                .scaleEffect(revealed ? 1 : 0.4)
                                .animation(.spring(response: 0.45, dampingFraction: 0.7).delay(Double(column) * 0.03), value: revealed)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ActivityCell: View {
    let day: ActivityDay?
    let peak: Double
    @State private var hovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(fill)
            .frame(maxWidth: .infinity)
            .frame(height: 16)
            .onHover { hovering = $0 }
            .tip(verbatim: label, show: hovering && day != nil)
    }

    private var fill: Color {
        guard let day else { return .clear }
        return day.minutes > 0 ? Palette.orange.opacity(0.25 + 0.75 * day.minutes / peak) : Palette.field
    }

    private var label: String {
        guard let day else { return "" }
        let date = day.date.formatted(.dateTime.month().day())
        let time = Duration.seconds(day.minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return day.minutes > 0 ? "\(date) · \(time)" : date
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
                                    Text("\(Duration.seconds(voice.seconds), format: .units(allowed: [.hours, .minutes], width: .abbreviated)) · \(voice.meetings) meetings")
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
        let peak = Double(terms.map(\.count).max() ?? 1)
        DashCard(title: "Your words", icon: "book-2") {
            if terms.isEmpty {
                Hint(text: "Terms from your vocabulary appear here once they come up in meetings.")
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(Array(terms.enumerated()), id: \.element.id) { index, term in
                        HStack(spacing: 5) {
                            Text(verbatim: term.term).font(Typo.bodyStrong)
                            Text(verbatim: "\(term.count)").font(Typo.caption).monospacedDigit().foregroundStyle(Palette.secondary)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Palette.orange.opacity(0.08 + 0.22 * Double(term.count) / peak), in: Capsule())
                        .opacity(revealed ? 1 : 0)
                        .offset(y: revealed ? 0 : 6)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(Double(index) * 0.03), value: revealed)
                    }
                }
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
