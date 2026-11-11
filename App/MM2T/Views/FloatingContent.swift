import MM2TApp
import MM2TCore
import MM2TSystem
import SwiftUI

/// What the processing queue most recently finished, shown in the capsule after a recording ends.
@MainActor @Observable
final class JobBanner {
    enum Outcome: Equatable {
        case done(MeetingID)
        case failed(MeetingID, reason: String)
    }

    private(set) var outcome: Outcome?
    @ObservationIgnored private var watched: MeetingID?
    @ObservationIgnored private var clearing: Task<Void, Never>?

    /// Call whenever the queue changes.
    func update(from queue: ProcessingQueue) {
        if let active = queue.activeJob {
            watched = active.id
            outcome = nil
            clearing?.cancel()
            return
        }
        guard let id = watched else { return }
        watched = nil
        switch queue.jobs[id] {
        case .completed:
            outcome = .done(id)
            clearing?.cancel()
            clearing = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { self?.outcome = nil }
            }
        case .failed(_, let reason):
            outcome = .failed(id, reason: reason)
        default:
            break
        }
    }

    func dismiss() {
        clearing?.cancel()
        outcome = nil
    }
}

/// What the floating panel shows: the capture state first, then processing and its result.
struct FloatingContent: View {
    let app: AppController
    let banner: JobBanner

    static func isShown(app: AppController, banner: JobBanner) -> Bool {
        app.capture.state != .idle || app.queue.activeJob != nil || banner.outcome != nil
    }

    var body: some View {
        ZStack {
            switch app.capture.state {
            case .idle:
                idle
            case .prompting(let meeting):
                MeetingPrompt(meeting: meeting, capture: app.capture)
            case .awaitingMicrophone:
                Status(icon: "microphone", text: "Allow microphone access to start recording")
            case .starting:
                Working(text: "Starting…")
            case .recording, .paused:
                RecordingCapsule(capture: app.capture)
            case .stopping:
                Working(text: "Saving…")
            case .failed(let failure):
                CaptureFailureView(failure: failure, capture: app.capture)
            }
        }
        .transition(.opacity)
        .capsuleChrome()
        .fixedSize()
        .motion(Motion.reveal, value: stage)
        // Room above the capsule for its buttons' tooltips.
        .padding(.top, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Which capsule is showing, so a change of kind animates while meter ticks do not.
    private var stage: String {
        switch app.capture.state {
        case .idle: app.queue.activeJob != nil ? "working" : banner.outcome == nil ? "none" : "outcome"
        case .prompting: "prompt"
        case .awaitingMicrophone: "mic"
        case .starting: "starting"
        case .recording: "recording"
        case .paused: "paused"
        case .stopping: "stopping"
        case .failed: "failed"
        }
    }

    @ViewBuilder private var idle: some View {
        if let job = app.queue.activeJob {
            Working(text: LocalizedStringKey(Copy.job(job.state)))
        } else {
            switch banner.outcome {
            case .done(let id):
                Status(icon: "circle-check", tint: Palette.success, text: LocalizedStringKey(title(id)))
            case .failed(let id, _):
                HStack(spacing: 10) {
                    Status(icon: "alert-triangle", tint: Palette.danger, text: "Processing failed")
                    CapsulePill("Retry") {
                        banner.dismiss()
                        Task { await app.meetings.process(id) }
                    }
                    CircleButton("Dismiss", icon: "x") { banner.dismiss() }
                }
            case nil:
                EmptyView()
            }
        }
    }

    private func title(_ id: MeetingID) -> String {
        app.meetings.rows.first { $0.id == id }?.title ?? ""
    }
}

extension View {
    /// The black pill every floating state sits in, dark regardless of the system appearance.
    func capsuleChrome() -> some View {
        font(Typo.bodyStrong)
            .foregroundStyle(.white)
            .padding(6)
            .background(.black, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1.5))
            .environment(\.colorScheme, .dark)
    }
}

/// An icon and one line of text inside the capsule.
struct Status: View {
    let icon: String
    var tint = Color.white
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 7) {
            Icon(icon, size: 16).foregroundStyle(tint)
            Text(text)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }
}

struct Working: View {
    let text: LocalizedStringKey
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .trim(from: 0.15, to: 1)
                .stroke(Palette.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(reduce ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
                .onAppear { spinning = true }
            Text(text).contentTransition(.opacity)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }
}

/// The capsule's round buttons: gray by default, white for the action that ends the recording.
struct CircleButton: View {
    enum Kind { case plain, primary, accent }

    let title: LocalizedStringKey
    let icon: String
    var kind = Kind.plain
    let action: () -> Void
    @State private var hovering = false

    init(_ title: LocalizedStringKey, icon: String, kind: Kind = .plain, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.kind = kind
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Icon(icon, size: 15)
                .foregroundStyle(kind == .primary ? .black : .white)
                .frame(width: 30, height: 30)
                .background(fill, in: Circle())
                .scaleEffect(hovering ? 1.08 : 1)
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
        .tip(title, show: hovering)
        .accessibilityLabel(title)
    }

    private var fill: Color {
        switch kind {
        case .plain: .white.opacity(hovering ? 0.32 : 0.22)
        case .primary: .white
        case .accent: Palette.orange
        }
    }
}

/// A text button inside the capsule.
struct CapsulePill: View {
    let title: LocalizedStringKey
    var filled = false
    let action: () -> Void
    @State private var hovering = false

    init(_ title: LocalizedStringKey, filled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.filled = filled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(Typo.captionStrong)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(filled ? Palette.orange.opacity(hovering ? 0.88 : 1) : .white.opacity(hovering ? 0.32 : 0.22), in: Capsule())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
    }
}

struct MeetingPrompt: View {
    let meeting: DetectedMeeting
    let capture: CaptureController

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Icon("video", size: 16)
                    Text("\(meeting.platform.displayName) meeting")
                }
                if meeting.client == .browser {
                    Text("The whole browser is recorded. Don't play other audio in it during the meeting.")
                        .font(Typo.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .padding(.leading, 10)
            CapsulePill("Record", filled: true) { Task { await capture.startPrompted() } }
                .keyboardShortcut(.defaultAction)
            CircleButton("Not This Time", icon: "x") { capture.dismiss() }
        }
    }
}

struct RecordingCapsule: View {
    let capture: CaptureController
    @State private var hovering = false

    var body: some View {
        CapsuleBar(
            isPaused: isPaused, level: level, elapsed: capture.meters.elapsed,
            remoteSilent: capture.meters.remoteSilentWhilePlaying, showsHighlight: hovering || isPaused,
            hasHighlights: capture.meters.highlightCount > 0,
            toggle: { Task { if isPaused { await capture.resume() } else { await capture.pause() } } },
            highlight: { Task { await capture.markHighlight() } },
            finish: { Task { await capture.stop() } })
            .onHover { hovering = $0 }
    }

    private var isPaused: Bool {
        if case .paused = capture.state { true } else { false }
    }

    /// One waveform for both tracks: whichever side is louder right now.
    private var level: Double {
        Double(max(capture.meters.me.meter(), capture.meters.remote.meter()))
    }
}

/// The recording capsule's layout, free of the recorder so it can be drawn with any values.
struct CapsuleBar: View {
    let isPaused: Bool
    let level: Double
    let elapsed: TimeInterval
    let remoteSilent: Bool
    let showsHighlight: Bool
    let hasHighlights: Bool
    let toggle: () -> Void
    let highlight: () -> Void
    let finish: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CircleButton(isPaused ? "Resume" : "Pause", icon: isPaused ? "player-play-filled" : "player-pause-filled",
                         kind: isPaused ? .accent : .plain, action: toggle)
            Waveform(level: isPaused || remoteSilent ? nil : level)
            if remoteSilent, !isPaused {
                Button {
                    SetupModel.openSettings(.systemAudio)
                } label: {
                    HStack(spacing: 6) {
                        Icon("volume-off", size: 15)
                        Text("Not hearing the other side")
                    }
                    .foregroundStyle(Palette.orange)
                }
                .buttonStyle(Pressable())
                .help("No meeting audio is reaching mm2t. Allow system audio recording in System Settings.")
                .transition(.opacity)
            } else {
                Text(Duration.seconds(elapsed), format: .time(pattern: .minuteSecond))
                    .monospacedDigit()
                    .opacity(isPaused ? 0.55 : 1)
                    .transition(.opacity)
            }
            if showsHighlight {
                CircleButton("Highlight", icon: hasHighlights ? "star-filled" : "star", action: highlight)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
            CircleButton("Finish", icon: "check", kind: .primary, action: finish)
        }
        .motion(Motion.select, value: showsHighlight)
        .motion(Motion.reveal, value: isPaused)
        .motion(Motion.reveal, value: remoteSilent)
    }
}

/// A centered, symmetric waveform. The newest level is the middle bar and older levels move
/// outward, so speech reads as a pulse spreading from the center. `nil` draws the flat resting line.
struct Waveform: View {
    let level: Double?
    @State private var history = Array(repeating: 0.0, count: Waveform.half)
    @Environment(\.snapshotWaveform) private var fixed

    private static let half = 6

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<(Self.half * 2 - 1), id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(level == nil ? 0.45 : 1))
                    .frame(width: 2.5, height: height(at: abs(index - (Self.half - 1))))
            }
        }
        .frame(height: 24)
        .animation(.easeOut(duration: 0.12), value: history)
        .onChange(of: level) { _, new in
            history.removeLast()
            history.insert(new ?? 0, at: 0)
        }
        .accessibilityHidden(true)
    }

    private func height(at distance: Int) -> CGFloat {
        guard level != nil else { return 3 }
        // Outer bars are shorter so the shape tapers like speech rather than a block.
        let taper = 1 - Double(distance) / Double(Self.half) * 0.75
        return 3 + 21 * (fixed ?? history)[distance] * taper
    }
}

struct CaptureFailureView: View {
    let failure: CaptureFailure
    let capture: CaptureController

    var body: some View {
        HStack(spacing: 10) {
            HStack(alignment: .top, spacing: 7) {
                Icon("alert-triangle", size: 16).foregroundStyle(Palette.danger)
                Text(Copy.failure(failure)).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 340, alignment: .leading)
            .padding(.leading, 10)
            if let pane = failure.settingsPane {
                CapsulePill("Open System Settings") { SetupModel.openSettings(pane) }
            }
            CircleButton("OK", icon: "x") { capture.acknowledgeFailure() }
        }
    }
}

private struct SnapshotWaveformKey: EnvironmentKey {
    static let defaultValue: [Double]? = nil
}

extension EnvironmentValues {
    /// Fixed bar levels for still pictures of the waveform; nil in the running app.
    var snapshotWaveform: [Double]? {
        get { self[SnapshotWaveformKey.self] }
        set { self[SnapshotWaveformKey.self] = newValue }
    }
}
