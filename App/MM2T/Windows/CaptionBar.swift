import AppKit
import MM2TApp
import SwiftUI

/// The floating caption bar: a borderless glass panel near the bottom of the capsule's screen that
/// shows live captions while recording. Like the capsule's panel it floats over every app and
/// Space, is kept out of screen captures, and never takes focus.
@MainActor
final class CaptionBarController {
    private let app: AppController
    private let panel: NSPanel
    private let host: NSHostingController<CaptionBarView>
    private let model = CaptionBarModel()
    /// Transparent room around the bar for its shadow (sides and bottom) and its tooltips (top).
    static let margin: CGFloat = 40
    static let topRoom: CGFloat = 48
    /// More than two lines of captions with their padding, and the original line above a translation.
    static let barRoom: CGFloat = 120
    static let width: CGFloat = 640
    static let minimumWidth: CGFloat = 420
    /// The bar's bottom edge sits this far above the bottom of the screen's visible frame.
    static let bottomInset: CGFloat = 96

    private var screenKey: String?
    private var defaultOrigin = NSPoint.zero
    private var drag: (mouse: NSPoint, origin: NSPoint)?
    private var reasonUntil: Date?
    private var reasonTask: Task<Void, Never>?
    private var leaving: Task<Void, Never>?

    init(app: AppController) {
        self.app = app
        let model = model
        host = NSHostingController(rootView: CaptionBarView(captions: app.capture.captions, model: model))
        // A fixed panel size; the bar animates inside it (see `FloatingPanelController`).
        host.sizingOptions = []
        panel = CaptionPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width + 2 * Self.margin, height: 200),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentViewController = host
        WindowSharing.exclude(panel)

        model.drag = { [weak self] in self?.dragged() }
        model.dragEnded = { [weak self] in self?.dragEnded() }
        model.hide = { [weak app] in app?.capture.captions.isBarHidden = true }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        observeChanges { [weak self] in self?.update() }
    }

    /// Captions run for this recording, the user has not hidden the bar, and an `unavailable`
    /// reason has not yet had its four seconds.
    private var wantsShown: Bool {
        let captions = app.capture.captions
        guard app.capture.state.isCapturing, !captions.isBarHidden, !MainNavigation.shared.liveFrontmost else { return false }
        switch captions.status {
        case .off: return false
        case .unavailable: return reasonUntil.map { Date() < $0 } ?? false
        case .connecting, .live, .reconnecting: return true
        }
    }

    private func update() {
        if case .unavailable = app.capture.captions.status {
            if reasonUntil == nil {
                reasonUntil = Date().addingTimeInterval(4)
                reasonTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    self?.update()
                }
            }
        } else {
            reasonUntil = nil
            reasonTask?.cancel()
        }
        if wantsShown {
            leaving?.cancel()
            leaving = nil
            if !panel.isVisible {
                place()
                panel.orderFrontRegardless()
            }
            if !model.shown { model.shown = true }
        } else if model.shown || panel.isVisible {
            model.shown = false
            leaving?.cancel()
            leaving = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, !self.model.shown else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    /// Centered on the screen that has the capsule, 96 pt above the bottom of its visible frame,
    /// moved by however far the user dragged it on that screen.
    private func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let barWidth = min(Self.width, max(Self.minimumWidth, visible.width - 32))
        if model.width != barWidth { model.width = barWidth }
        let size = NSSize(width: barWidth + 2 * Self.margin, height: Self.topRoom + Self.barRoom + Self.margin)
        defaultOrigin = NSPoint(x: screen.frame.midX - size.width / 2, y: visible.minY + Self.bottomInset - Self.margin)
        screenKey = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
        let offset = screenKey.flatMap { app.settings.settings.captionBarOffsets[$0] }
        var origin = NSPoint(x: defaultOrigin.x + (offset?.x ?? 0), y: defaultOrigin.y + (offset?.y ?? 0))
        // Never lost off the screen it belongs to.
        origin.x = min(max(origin.x, screen.frame.minX - Self.margin), screen.frame.maxX - size.width + Self.margin)
        origin.y = min(max(origin.y, screen.frame.minY - Self.margin), screen.frame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func dragged() {
        let mouse = NSEvent.mouseLocation
        if drag == nil { drag = (mouse, panel.frame.origin) }
        guard let drag else { return }
        panel.setFrameOrigin(NSPoint(x: drag.origin.x + mouse.x - drag.mouse.x, y: drag.origin.y + mouse.y - drag.mouse.y))
    }

    private func dragEnded() {
        drag = nil
        guard let screenKey else { return }
        let origin = panel.frame.origin
        app.settings.settings.captionBarOffsets[screenKey] = CaptionBarOffset(
            x: Double(origin.x - defaultOrigin.x), y: Double(origin.y - defaultOrigin.y))
    }
}

/// A panel that never becomes key or main, so the bar cannot take focus or come to front as a window.
private final class CaptionPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable
final class CaptionBarModel {
    var shown = false
    var width = CaptionBarController.width
    @ObservationIgnored var drag: () -> Void = {}
    @ObservationIgnored var dragEnded: () -> Void = {}
    @ObservationIgnored var hide: () -> Void = {}
}

struct CaptionBarView: View {
    let captions: LiveCaptions
    let model: CaptionBarModel
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var arrivals = CaptionArrivals()
    @State private var runs: [CaptionRun] = []
    @State private var lineHeight: CGFloat = 24
    @State private var textHeight: CGFloat = 24
    @State private var hovering = false
    @State private var quiet = false
    @State private var settling = false

    static let font = Font.system(size: 18, weight: .medium, design: .rounded)
    static let originalFont = Font.system(size: 13, weight: .regular, design: .rounded)
    static let lineSpacing: CGFloat = 4
    /// New characters reach full opacity, and lose their blur, over this long.
    static let arrival: TimeInterval = 0.18

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            bar
        }
        .padding(.horizontal, CaptionBarController.margin)
        .padding(.bottom, CaptionBarController.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(model.shown ? 1 : 0)
        .offset(y: model.shown || reduce ? 0 : 6)
        .animation(reduce ? .easeOut(duration: 0.12) : model.shown ? Motion.reveal : .easeOut(duration: 0.15), value: model.shown)
        .tipLayer()
        .onChange(of: captions.segments, initial: true) { refresh() }
        .onChange(of: captions.partialMainText) { refresh() }
        .onChange(of: captions.awaitingTranslation) { refresh() }
        .task(id: captions.lastActivity) {
            quiet = false
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled, captions.lastActivity != nil { quiet = true }
        }
        .task(id: runs.map(\.arrived).max()) {
            guard let latest = runs.map(\.arrived).max(), Date().timeIntervalSince(latest) < Self.arrival else { return }
            settling = true
            try? await Task.sleep(for: .milliseconds(Int(Self.arrival * 1000) + 30))
            if !Task.isCancelled { settling = false }
        }
    }

    private var bar: some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(width: model.width, alignment: .leading)
            .modifier(PlaybackGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)))
            .shadow(color: Palette.shadow, radius: 24, y: 10)
            .overlay(alignment: .topTrailing) {
                if captions.status == .reconnecting {
                    Circle().fill(Palette.orange).frame(width: 6, height: 6).padding(9)
                        .transition(.opacity)
                        .accessibilityLabel("Reconnecting")
                }
            }
            .overlay(alignment: .trailing) {
                if hovering {
                    HStack(spacing: 6) {
                        GlassControl("Open Live Page", icon: "maximize") { MainNavigation.shared.openLive() }
                        GlassControl("Hide Captions", icon: "x", action: model.hide)
                    }
                    .padding(.trailing, 12)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .motion(Motion.reveal, value: captions.status)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { _ in model.drag() }
                .onEnded { _ in model.dragEnded() })
            .background(alignment: .topLeading) {
                // Measures one line so the bar can hold exactly one or two.
                Text(verbatim: "Ag").font(Self.font).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { lineHeight = $0 }
            }
    }

    @ViewBuilder private var content: some View {
        if case .unavailable(let reason) = captions.status {
            Text(verbatim: reason)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Palette.text)
                .opacity(0.7)
                .lineLimit(2)
                .shadow(color: Palette.shadow, radius: 2, y: 1)
                .frame(maxWidth: .infinity, minHeight: lineHeight, alignment: .leading)
        } else if runs.isEmpty && !captions.newestIsTranslated {
            // Waiting for the first words: three still dots.
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 5, height: 5) }
            }
            .foregroundStyle(Palette.text)
            .opacity(0.4)
            .frame(maxWidth: .infinity, minHeight: lineHeight, maxHeight: lineHeight, alignment: .leading)
            .accessibilityLabel("Listening")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if captions.newestIsTranslated {
                    // The words as spoken, one line, cut at the start so the newest stay visible.
                    Text(verbatim: original)
                        .font(Self.originalFont)
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .shadow(color: Palette.shadow, radius: 2, y: 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                captionText
            }
            .motion(Motion.reveal, value: captions.newestIsTranslated)
        }
    }

    /// The recent original words behind the translated main text.
    private var original: String {
        var text = ""
        for segment in CaptionArrivals.recent(captions.segments) {
            text += CaptionArrivals.joiner(text, segment.text) + segment.text
        }
        if !captions.partial.isEmpty { text += CaptionArrivals.joiner(text, captions.partial) + captions.partial }
        return text
    }

    /// Two lines at most, filling from the leading edge; the newest line is always the bottom one
    /// and older lines leave upward.
    private var captionText: some View {
        let visible = min(max(textHeight, lineHeight), 2 * lineHeight + Self.lineSpacing)
        return TimelineView(.animation(minimumInterval: 1 / 30, paused: !settling)) { timeline in
            styled(at: timeline.date)
                .font(Self.font)
                .lineSpacing(Self.lineSpacing)
                .contentTransition(.identity)
                .shadow(color: Palette.shadow, radius: 2, y: 1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
        }
        .frame(height: visible, alignment: .bottom)
        .clipped()
        .opacity(quiet ? 0.35 : 1)
        .motion(Motion.reveal, value: quiet)
        .motion(Motion.reveal, value: visible)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: runs.map(\.text).joined()))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func styled(at date: Date) -> some View {
        var result = Text(verbatim: "")
        for run in runs {
            let progress = min(1, max(0, date.timeIntervalSince(run.arrived) / Self.arrival))
            var attributed = AttributedString(run.text)
            attributed.foregroundColor = (run.isPartial ? Palette.secondary : Palette.text).opacity(progress)
            var part = Text(attributed)
            if #available(macOS 15, *) {
                part = part.customAttribute(AssistantTextAttribute(blur: reduce ? 0 : 3 * (1 - progress), citation: nil))
            }
            result = result + part
        }
        return Group {
            if #available(macOS 15, *) {
                result.textRenderer(AssistantTextRenderer(regions: .constant([])))
            } else {
                result
            }
        }
    }

    private func refresh() {
        // With translation on, the main text is the translation; segments still being translated wait.
        let next = arrivals.update(segments: CaptionArrivals.recent(captions.displaySegments),
                                   partial: captions.partialMainText, now: Date())
        // A new line pushes the older ones up by one line; under Reduce Motion it just appears.
        withAnimation(reduce ? nil : Motion.select) { runs = next }
    }
}

/// A round control on glass, as the assistant composer draws its secondary button.
struct GlassControl: View {
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
            Icon(icon, size: 14)
                .foregroundStyle(Palette.text)
                .frame(width: 30, height: 30)
                .background(hovering ? Palette.selected : Palette.field, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(Pressable())
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
        .tip(title, show: hovering)
        .accessibilityLabel(title)
    }
}
