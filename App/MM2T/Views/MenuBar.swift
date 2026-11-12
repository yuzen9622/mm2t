import MM2TApp
import MM2TCore
import MM2TSystem
import Sparkle
import SwiftUI

struct MenuBarLabel: View {
    let app: AppController?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .onAppear { WindowOpener.register(openWindow) }
    }

    private var symbol: String {
        switch app?.capture.state {
        case .recording, .endingSoon: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .prompting: "waveform.badge.exclamationmark"
        default: app?.queue.activeJob == nil ? "waveform" : "waveform.badge.ellipsis"
        }
    }
}

/// What a recording's meters read, so the menu can be drawn without a running recorder.
struct MeterReading: Equatable {
    var me: Double
    var remote: Double
    var elapsed: TimeInterval
    var highlights: Int
    var remoteSilent: Bool

    @MainActor init(_ meters: RecordingMeters) {
        self.init(me: Double(meters.me.meter()), remote: Double(meters.remote.meter()), elapsed: meters.elapsed,
                  highlights: meters.highlightCount, remoteSilent: meters.remoteSilentWhilePlaying)
    }

    init(me: Double, remote: Double, elapsed: TimeInterval, highlights: Int, remoteSilent: Bool) {
        self.me = me
        self.remote = remote
        self.elapsed = elapsed
        self.highlights = highlights
        self.remoteSilent = remoteSilent
    }
}

/// The menu bar window: what mm2t is doing now and the one thing to do about it, then what is
/// coming up and what was recorded last. Drawn in the app's own cards and buttons.
struct MenuBarContent: View {
    let app: AppController
    /// A capture state and meters to draw instead of the recorder's, for still pictures.
    var preview: (state: CaptureState, meters: MeterReading)?
    /// Whether to draw the menu as after setup, for still pictures; nil reads the app.
    var previewSetUp: Bool?
    @Environment(\.dismiss) private var dismiss

    private var state: CaptureState { preview?.state ?? app.capture.state }
    private var meters: MeterReading { preview?.meters ?? MeterReading(app.capture.meters) }
    private var needsOnboarding: Bool { previewSetUp.map { !$0 } ?? app.needsOnboarding }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            CaptureCard(state: state, meters: meters, needsOnboarding: needsOnboarding, capture: app.capture)
            if let job = app.queue.activeJob {
                ProcessingRow(title: title(job.id), detail: Copy.job(job.state))
                    .transition(.opacity)
            }
            if !app.recovered.isEmpty {
                RecoveredNotice(count: app.recovered.count) { go(.meetings) }
            }
            NextUp(model: app.dashboard)
            RecentMeetings(rows: recent) { go(.meetings, meeting: $0) }
            footer
        }
        .padding(14)
        .frame(width: 332, alignment: .leading)
        .background(Palette.window)
        .foregroundStyle(Palette.text)
        .font(Typo.body)
        .tipLayer()
        .motion(Motion.reveal, value: app.queue.activeJob?.id)
        .task { await app.dashboard.reloadCalendar() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Icon("microphone", size: 16)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Palette.orange, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "mm2t").font(Typo.heading)
                Text(status).font(Typo.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            if state.isCapturing {
                RecordingDot().transition(.scale.combined(with: .opacity))
            }
        }
        .motion(Motion.reveal, value: status)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Rectangle().fill(Palette.border).frame(height: 1)
            HStack(spacing: 2) {
                IconButton("Meetings", icon: "messages") { go(.meetings) }
                IconButton("Settings", icon: "settings") { go(.settings) }
                UpdatesButton()
                Spacer()
                IconButton("Quit mm2t", icon: "power") { NSApp.terminate(nil) }
            }
        }
    }

    private var status: String {
        switch state {
        case .idle:
            if app.queue.activeJob != nil { return String(localized: "Processing…") }
            return needsOnboarding ? String(localized: "Setup isn't finished") : String(localized: "Ready")
        case .prompting(let meeting): return String(localized: "\(meeting.platform.displayName) detected")
        case .recording(let target): return String(localized: "Recording \(target.name)")
        case .paused: return String(localized: "Paused")
        case .endingSoon: return String(localized: "Meeting ended")
        case .failed: return String(localized: "Couldn't record")
        case .awaitingMicrophone, .starting, .stopping: return Copy.capture(state)
        }
    }

    private var recent: [MeetingRow] {
        Array(app.meetings.rows.sorted { $0.startedAt > $1.startedAt }.prefix(3))
    }

    private func title(_ id: MeetingID) -> String {
        app.meetings.rows.first { $0.id == id }?.title ?? ""
    }

    private func go(_ section: SidebarItem, meeting: MeetingID? = nil) {
        MainNavigation.shared.open(section, meeting: meeting)
        dismiss()
    }
}

/// The menu's main card, following the capture state.
private struct CaptureCard: View {
    let state: CaptureState
    let meters: MeterReading
    let needsOnboarding: Bool
    let capture: CaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state {
            case .idle:
                if needsOnboarding {
                    Text("mm2t needs your permissions and keys before it can take notes.")
                        .font(Typo.caption).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    WideButton("Continue Setup", icon: "settings") { WindowOpener.open(WindowID.onboarding) }
                } else {
                    WideButton("Start Recording", icon: "microphone") {
                        Task { await capture.startNow(title: String(localized: "Recording")) }
                    }
                }
            case .prompting(let meeting):
                HStack(spacing: 8) {
                    Icon("video", size: 18).foregroundStyle(Palette.orange)
                    Text("\(meeting.platform.displayName) meeting").font(Typo.heading)
                }
                if meeting.client == .browser {
                    Text("The whole browser is recorded. Don't play other audio in it during the meeting.")
                        .font(Typo.caption).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    WideButton("Record", icon: "microphone") { Task { await capture.startPrompted() } }
                    PillButton("Not This Time") { capture.dismiss() }
                }
            case .recording(let target), .paused(let target):
                recording(target, paused: { if case .paused = state { true } else { false } }())
            case .endingSoon(_, let deadline):
                MenuCountdown(deadline: deadline)
                HStack(spacing: 8) {
                    WideButton("Keep Recording", icon: "player-play-filled") { Task { await capture.keepRecording() } }
                    PillButton("Stop Now", icon: "player-stop") { Task { await capture.stop() } }
                }
            case .failed(let failure):
                HStack(alignment: .top, spacing: 8) {
                    Icon("alert-triangle", size: 16).foregroundStyle(Palette.danger)
                    Text(Copy.failure(failure)).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if let pane = failure.settingsPane {
                        PillButton("Open System Settings", icon: "external-link", kind: .primary) { SetupModel.openSettings(pane) }
                    }
                    PillButton("OK") { capture.acknowledgeFailure() }
                }
            case .awaitingMicrophone, .starting, .stopping:
                HStack(spacing: 8) {
                    Spinner()
                    Text(Copy.capture(state)).foregroundStyle(Palette.secondary)
                }
            }
        }
        .card()
        .motion(Motion.reveal, value: kind)
    }

    @ViewBuilder private func recording(_ target: RecordingTarget, paused: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Duration.seconds(meters.elapsed), format: .time(pattern: .minuteSecond))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .opacity(paused ? 0.5 : 1)
            Spacer()
            Text(paused ? "Paused" : "Recording in progress")
                .font(Typo.captionStrong)
                .foregroundStyle(paused ? Palette.secondary : Palette.danger)
        }
        Text(verbatim: target.name).font(Typo.caption).foregroundStyle(Palette.secondary).lineLimit(1)
        VStack(spacing: 6) {
            TrackMeter(title: "Me", level: paused ? nil : meters.me)
            TrackMeter(title: "Others", level: paused ? nil : meters.remote)
        }
        if meters.remoteSilent, !paused {
            Button { SetupModel.openSettings(.systemAudio) } label: {
                HStack(spacing: 6) {
                    Icon("volume-off", size: 14)
                    Text("Not hearing the other side").font(Typo.captionStrong)
                }
                .foregroundStyle(Palette.orange)
            }
            .buttonStyle(Pressable())
        }
        HStack(spacing: 4) {
            IconButton(paused ? "Resume" : "Pause", icon: paused ? "player-play-filled" : "player-pause-filled", isOn: paused) {
                Task { if paused { await capture.resume() } else { await capture.pause() } }
            }
            IconButton("Highlight", icon: meters.highlights > 0 ? "star-filled" : "star") { Task { await capture.markHighlight() } }
            if meters.highlights > 0 {
                Text(verbatim: "\(meters.highlights)").font(Typo.captionStrong).foregroundStyle(Palette.secondary).monospacedDigit()
            }
            Spacer()
            PillButton("Finish", icon: "check", kind: .primary) { Task { await capture.stop() } }
        }
    }

    private var kind: String {
        switch state {
        case .idle: "idle"
        case .prompting: "prompt"
        case .recording, .paused: "recording"
        case .endingSoon: "ending"
        case .failed: "failed"
        case .awaitingMicrophone, .starting, .stopping: "working"
        }
    }
}

/// A full-width orange button for the card's one main action.
private struct WideButton: View {
    let title: LocalizedStringKey
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Icon(icon, size: 16)
                Text(title).font(Typo.bodyStrong)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(Palette.orange.opacity(hovering ? 0.88 : 1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
    }
}

/// One track's live level as a bar.
private struct TrackMeter: View {
    let title: LocalizedStringKey
    let level: Double?

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Typo.caption).foregroundStyle(Palette.secondary).frame(width: 40, alignment: .leading)
            GeometryReader { proxy in
                Capsule().fill(Palette.field)
                    .overlay(alignment: .leading) {
                        Capsule().fill(level == nil ? Palette.muted : Palette.orange)
                            .frame(width: max(4, proxy.size.width * (level ?? 0)))
                    }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.12), value: level)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

/// The end-of-meeting countdown, as in the notch island.
private struct MenuCountdown: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let left = max(1, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
            HStack(spacing: 10) {
                Text(verbatim: "\(left)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .foregroundStyle(Palette.orange)
                    .frame(width: 30, height: 30)
                    .overlay(Circle().strokeBorder(Palette.orange, lineWidth: 2))
                Text("The meeting ended. Recording stops in \(left) seconds.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .motion(Motion.select, value: left)
        }
    }
}

private struct ProcessingRow: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Spinner()
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title.isEmpty ? "–" : title).font(Typo.bodyStrong).lineLimit(1)
                Text(verbatim: detail).font(Typo.caption).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .card()
    }
}

private struct RecoveredNotice: View {
    let count: Int
    let show: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Icon("alert-triangle", size: 16).foregroundStyle(Palette.orange)
            Text("\(count) interrupted recordings were recovered.").font(Typo.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            PillButton("Show Meetings", action: show).fixedSize()
        }
        .card()
    }
}

/// A titled list in the menu, the way the dashboard labels its cards.
private struct MenuSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Typo.captionStrong).foregroundStyle(Palette.secondary).padding(.leading, 8)
            content
        }
    }
}

/// Today's next one or two meetings from the connected calendars, with their Join buttons.
private struct NextUp: View {
    let model: DashboardModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let events = upcoming(context.date)
            if !events.isEmpty {
                MenuSection(title: "Next Up") {
                    ForEach(events) { event in UpcomingRow(event: event, now: context.date) }
                }
            }
        }
    }

    private func upcoming(_ now: Date) -> [CalendarEvent] {
        guard model.hasConnectedCalendar else { return [] }
        return Array(model.events(on: now).filter { !$0.isAllDay && $0.end > now }.prefix(2))
    }
}

private struct UpcomingRow: View {
    let event: CalendarEvent
    let now: Date

    private var isLive: Bool { event.start <= now }
    /// Starting within ten minutes counts as live for the Join button, as on the dashboard.
    private var isSoon: Bool { event.start.timeIntervalSince(now) < 600 }

    var body: some View {
        HStack(spacing: 10) {
            Capsule().fill(isLive || isSoon ? Palette.orange : Palette.orange.opacity(0.35)).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: event.title.isEmpty ? "–" : event.title).font(Typo.bodyStrong).lineLimit(1)
                HStack(spacing: 4) {
                    Text(event.start, format: .dateTime.hour().minute())
                    Text(verbatim: "–")
                    Text(event.end, format: .dateTime.hour().minute())
                    if isLive { Text("· Now").foregroundStyle(Palette.orange) }
                }
                .font(Typo.caption).foregroundStyle(Palette.secondary).monospacedDigit()
            }
            Spacer(minLength: 6)
            if let link = event.link {
                PillButton("Join", icon: "video", kind: isLive || isSoon ? .primary : .ghost) { NSWorkspace.shared.open(link) }
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// The last few meetings; one opens in the main window.
private struct RecentMeetings: View {
    let rows: [MeetingRow]
    let open: (MeetingID) -> Void

    var body: some View {
        if !rows.isEmpty {
            MenuSection(title: "Recent Meetings") {
                ForEach(rows) { row in RecentRow(row: row) { open(row.id) } }
            }
        }
    }
}

private struct RecentRow: View {
    let row: MeetingRow
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Icon("messages", size: 15).foregroundStyle(Palette.secondary)
                Text(verbatim: row.title.isEmpty ? "–" : row.title).font(Typo.bodyStrong).lineLimit(1)
                Spacer(minLength: 6)
                Text(row.startedAt, format: .relative(presentation: .named))
                    .font(Typo.caption).foregroundStyle(Palette.secondary).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(hovering ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
    }
}

/// Check for Updates as an icon, with the same rules as the menu command: shown only when updates
/// are configured, and dimmed while a check cannot start.
private struct UpdatesButton: View {
    @State private var canCheck = false

    var body: some View {
        if Updates.isConfigured {
            IconButton("Check for Updates…", icon: "refresh") { Updates.controller.checkForUpdates(nil) }
                .disabled(!canCheck)
                .opacity(canCheck ? 1 : 0.4)
                .onReceive(Updates.controller.updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
        }
    }
}

extension Copy {
    static func capture(_ state: CaptureState) -> String {
        switch state {
        case .awaitingMicrophone: String(localized: "Waiting for microphone permission")
        case .starting: String(localized: "Starting…")
        case .stopping: String(localized: "Saving…")
        case .failed(let failure): Self.failure(failure)
        default: ""
        }
    }
}
