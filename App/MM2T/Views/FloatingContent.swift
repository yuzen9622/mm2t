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

/// What the floating panel shows: the capture state first, then processing and its result, in an
/// island that grows out of the notch.
struct FloatingContent: View {
    let app: AppController
    let banner: JobBanner
    let notch: NotchModel

    static func isShown(app: AppController, banner: JobBanner) -> Bool {
        app.capture.state != .idle || app.queue.activeJob != nil || banner.outcome != nil
    }

    var body: some View {
        NotchIsland(metrics: notch.metrics, stays: staysOpen) {
            expanded
        } leading: {
            leadingWing
        } trailing: {
            trailingWing
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .tipLayer(prefersBelow: true)
    }

    /// States that ask for an answer or report something open by themselves; the rest wait for
    /// the pointer.
    private var staysOpen: Bool {
        switch app.capture.state {
        case .prompting, .awaitingMicrophone, .endingSoon, .failed: true
        case .idle: app.queue.activeJob == nil && banner.outcome != nil
        case .starting, .recording, .paused, .stopping: false
        }
    }

    @ViewBuilder private var expanded: some View {
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
            case .endingSoon(_, let deadline):
                EndingSoon(deadline: deadline, keep: { Task { await app.capture.keepRecording() } },
                           stop: { Task { await app.capture.stop() } })
            case .stopping:
                Working(text: "Saving…")
            case .failed(let failure):
                CaptureFailureView(failure: failure, capture: app.capture)
            }
        }
        .transition(.opacity)
        .motion(Motion.reveal, value: stage)
    }

    @ViewBuilder private var leadingWing: some View {
        switch app.capture.state {
        case .recording: RecordingDot()
        case .paused: Icon("player-pause-filled", size: 13).foregroundStyle(Palette.orange)
        case .starting, .stopping: Spinner()
        case .idle where app.queue.activeJob != nil: Spinner()
        default: EmptyView()
        }
    }

    @ViewBuilder private var trailingWing: some View {
        switch app.capture.state {
        case .recording: MiniMeter(level: level)
        case .paused: MiniMeter(level: nil)
        default: EmptyView()
        }
    }

    private var level: Double {
        Double(max(app.capture.meters.me.meter(), app.capture.meters.remote.meter()))
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
        case .endingSoon: "ending"
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

/// A black shape that hangs from the screen's top edge and merges with the notch. At rest it is
/// the notch plus a wing on each side for a glanceable status; under the pointer, or while
/// `stays`, it springs open downward to show `expanded`. Without a notch it is a small pill
/// hanging from the menu bar.
struct NotchIsland<Expanded: View, Leading: View, Trailing: View>: View {
    let metrics: NotchMetrics
    let stays: Bool
    /// Draws the island open without the pointer, for still pictures.
    var forcesOpen = false
    @ViewBuilder let expanded: Expanded
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @State private var hovering = false
    @State private var openSize = CGSize.zero

    /// The width of each wing beside the notch.
    static var wing: CGFloat { 34 }

    private var isOpen: Bool { stays || hovering || forcesOpen }
    private var shape: NotchShape { NotchShape(ear: isOpen ? 12 : 6, radius: isOpen ? 22 : min(10, metrics.height / 2)) }
    private var restWidth: CGFloat { metrics.width + Self.wing * 2 }

    var body: some View {
        ZStack(alignment: .top) {
            expanded
                .padding(.top, metrics.height + 4)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
                .frame(minWidth: restWidth)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { openSize = $0 }
                .opacity(isOpen ? 1 : 0)
                .scaleEffect(isOpen ? 1 : 0.9, anchor: .top)
                .allowsHitTesting(isOpen)
            HStack(spacing: 0) {
                // EmptyView takes no space, even with a frame. Keep both wings present so
                // a lone spinner stays beside the physical notch instead of shifting under it.
                Color.clear.frame(width: Self.wing).overlay { leading }
                Color.clear.frame(width: metrics.width)
                Color.clear.frame(width: Self.wing).overlay { trailing }
            }
            .frame(height: metrics.height)
            .opacity(isOpen ? 0 : 1)
        }
        .frame(width: isOpen ? max(openSize.width, restWidth) : restWidth,
               height: isOpen ? max(openSize.height, metrics.height) : metrics.height, alignment: .top)
        .padding(.horizontal, shape.ear)
        .clipShape(shape)
        .background(.black, in: shape)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .font(Typo.bodyStrong)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .motion(Motion.select, value: isOpen)
        .accessibilityElement(children: .contain)
    }
}

/// The island's outline: a full-width top edge whose corners curve outward into the screen's edge
/// like the notch's, straight sides and rounded bottom corners.
struct NotchShape: Shape {
    var ear: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, radius) }
        set { ear = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(radius, rect.height / 2, (rect.width - ear * 2) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + ear, y: rect.minY + ear), control: CGPoint(x: rect.minX + ear, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + ear, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + ear + radius, y: rect.maxY), control: CGPoint(x: rect.minX + ear, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - ear - radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - ear, y: rect.maxY - radius), control: CGPoint(x: rect.maxX - ear, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - ear, y: rect.minY + ear))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - ear, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The resting island's sign that it is recording: a red dot that breathes.
struct RecordingDot: View {
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Circle().fill(Palette.danger).frame(width: 8, height: 8)
            .opacity(dim ? 0.45 : 1)
            .animation(reduce ? nil : .easeInOut(duration: 1).repeatForever(), value: dim)
            .onAppear { dim = true }
            .accessibilityLabel("Recording")
    }
}

/// Four bars that follow the louder track, sized for the resting island's wing; flat while paused.
struct MiniMeter: View {
    let level: Double?
    private static let shape: [Double] = [0.55, 1, 0.75, 0.4]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.shape.indices, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(level == nil ? 0.45 : 1))
                    .frame(width: 2.5, height: 3 + 11 * (level ?? 0) * Self.shape[index])
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }
}

/// The small orange ring that turns while something is under way.
struct Spinner: View {
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 1)
            .stroke(Palette.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(reduce ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

/// The meeting app went quiet: recording stops at `deadline` unless the user keeps it going.
struct EndingSoon: View {
    let deadline: Date
    let keep: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                let left = max(1, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                HStack(spacing: 8) {
                    Text(verbatim: "\(left)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(Palette.orange, lineWidth: 2))
                    Text("The meeting ended. Recording stops in \(left) seconds.")
                        .contentTransition(.numericText(countsDown: true))
                }
                .motion(Motion.select, value: left)
            }
            .padding(.leading, 6)
            CapsulePill("Keep Recording", filled: true, action: keep)
            CapsulePill("Stop Now", action: stop)
        }
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

    var body: some View {
        HStack(spacing: 8) {
            Spinner()
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
            Waveform(level: isPaused ? nil : level)
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
