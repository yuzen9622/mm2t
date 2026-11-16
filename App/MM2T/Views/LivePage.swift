import MM2TApp
import SwiftUI

/// The recording in progress inside the main window: its clock and controls, and the live captions
/// as paragraphs that follow the newest words. Collapsing returns to the page underneath; the
/// recording goes on in the capsule.
struct LivePage: View {
    let app: AppController
    let collapse: () -> Void
    @State private var follow = AssistantFollowScroll()
    @Environment(\.controlActiveState) private var activeState

    private var capture: CaptureController { app.capture }
    private var captions: LiveCaptions { app.capture.captions }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Text("Live captions are a preview. The saved transcript is produced after the meeting.")
                .font(Typo.caption)
                .foregroundStyle(Palette.muted)
                .lineLimit(2)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            if app.settings.settings.liveCaptions || captions.isActive {
                if captions.segments.isEmpty && captions.partial.isEmpty {
                    placeholder(title: "Listening…", detail: "Captions appear here as people speak.")
                } else {
                    transcript
                }
            } else {
                placeholder(title: "Live captions are off", detail: nil)
            }
        }
        .background(Palette.window)
        .onChange(of: activeState, initial: true) { MainNavigation.shared.liveFrontmost = activeState == .key }
        .onDisappear { MainNavigation.shared.liveFrontmost = false }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if isPaused {
                Icon("player-pause-filled", size: 13).foregroundStyle(Palette.orange).accessibilityLabel("Paused")
            } else {
                RecordingDot()
            }
            Text(Duration.seconds(capture.meters.elapsed), format: .time(pattern: .minuteSecond))
                .font(Typo.heading)
                .monospacedDigit()
            if let name = capture.state.target?.name {
                Text(verbatim: name).font(Typo.body).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            PillButton(isPaused ? "Resume" : "Pause", icon: isPaused ? "player-play" : "player-pause") {
                Task { if isPaused { await capture.resume() } else { await capture.pause() } }
            }
            .disabled(!capture.state.isCapturing)
            PillButton("Stop", icon: "player-stop") { Task { await capture.stop() } }
                .disabled(!capture.state.isCapturing)
            IconButton("Collapse to Capsule", icon: "arrows-diagonal-minimize-2", action: collapse)
        }
        .padding(.horizontal, 24)
        .frame(height: 60)
        .zIndex(1)
    }

    private var isPaused: Bool {
        if case .paused = capture.state { true } else { false }
    }

    /// Finished segments as paragraphs, the unfinished one inline after them in a lighter tone.
    private var transcript: some View {
        let paragraphs = captions.paragraphs
        return FadingScrollView(ground: Palette.window) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(paragraphs.enumerated()), id: \.element.first?.id) { index, paragraph in
                    paragraphText(paragraph, partial: index == paragraphs.count - 1 ? captions.partial : "")
                }
                if paragraphs.isEmpty, !captions.partial.isEmpty {
                    paragraphText([], partial: captions.partial)
                }
            }
            .font(Typo.reading)
            .lineSpacing(Typo.readingLineSpacing)
            .textSelection(.enabled)
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity)
            .background(FollowScrollObserver(follow: $follow))
        }
        .overlay(alignment: .bottom) {
            if !follow.follows {
                // Same as the assistant: following resumes once the view is back at its end.
                PillButton("Jump to Live", icon: "chevron-right") { follow.sent() }
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: follow.follows)
    }

    private func paragraphText(_ paragraph: [LiveCaptions.Segment], partial: String) -> some View {
        let finished = paragraph.map(\.text).reduce("") { text, next in text + CaptionArrivals.joiner(text, next) + next }
        var line = Text(verbatim: finished).foregroundStyle(Palette.text)
        if !partial.isEmpty {
            line = line + Text(verbatim: CaptionArrivals.joiner(finished, partial) + partial).foregroundStyle(Palette.muted)
        }
        return line
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.updatesFrequently)
    }

    private func placeholder(title: LocalizedStringKey, detail: LocalizedStringKey?) -> some View {
        VStack(spacing: 10) {
            Icon("badge-cc", size: 30).foregroundStyle(Palette.muted)
            Text(title).foregroundStyle(Palette.secondary)
            if let detail {
                Text(detail).font(Typo.caption).foregroundStyle(Palette.muted)
            } else {
                PillButton("Open Settings") { MainNavigation.shared.open(.settings) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
