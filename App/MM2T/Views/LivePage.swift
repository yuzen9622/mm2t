import MM2TApp
import SwiftUI

/// The recording in progress inside the main window: its clock and controls, and the live captions
/// as paragraphs that follow the newest words. Collapsing returns to the page underneath; the
/// recording goes on in the capsule.
struct LivePage: View {
    let app: AppController
    let collapse: () -> Void
    @State private var selected = Tab.shared
    private enum Tab: CaseIterable { case shared, captions }
    @State private var follow = AssistantFollowScroll()
    @Environment(\.controlActiveState) private var activeState

    private var capture: CaptureController { app.capture }
    private var captions: LiveCaptions { app.capture.captions }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let collaboration = capture.collaboration, let room = collaboration.room {
                Segmented(options: Tab.allCases, selection: $selected) { tab in
                    switch tab {
                    case .captions: String(localized: "Captions")
                    case .shared: String(localized: "Shared")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
                if selected == .shared {
                    HStack {
                        if collaboration.hostBrowserFailed { Text("Couldn’t open the host page.") }
                        Spacer()
                        PillButton("Open in Browser as Host", icon: "external-link") {
                            Task { await collaboration.openHostBrowser { NSWorkspace.shared.open($0) } }
                        }
                        .disabled(collaboration.openingHostBrowser)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
                    CollabHostView(page: .shared, url: room.hostUrl).id(room.roomId)
                } else {
                    captionBody
                }
            } else {
                captionBody
            }
        }
        .background(Palette.window)
        .onChange(of: MainNavigation.shared.collaborationRequest) { selected = .shared }
        .onChange(of: showingCaptionsInKeyWindow, initial: true) {
            MainNavigation.shared.liveFrontmost = showingCaptionsInKeyWindow
        }
        .onDisappear { MainNavigation.shared.liveFrontmost = false }
    }

    private var showingCaptionsInKeyWindow: Bool {
        activeState == .key && (capture.collaboration?.room == nil || selected == .captions)
    }

    @ViewBuilder private var captionBody: some View {
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
                    VStack(alignment: .leading, spacing: 4) {
                        paragraphText(paragraph, partial: index == paragraphs.count - 1 ? captions.partial : "")
                        if let translation = translation(of: paragraph) {
                            Text(verbatim: translation)
                                .foregroundStyle(Palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.opacity.animation(.easeOut(duration: 0.18)))
                        }
                    }
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

    /// The paragraph's segments' translations, joined the way their originals are; nil when none
    /// was translated (already in the target language, or translation is off).
    private func translation(of paragraph: [LiveCaptions.Segment]) -> String? {
        // A translation once shown stays: until a segment's own arrives, its interim one stands in.
        let parts = paragraph.compactMap(captions.shownTranslation)
        guard !parts.isEmpty else { return nil }
        return parts.reduce("") { text, next in text + CaptionArrivals.joiner(text, next) + next }
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
