import AppKit
import MM2TApp
import MM2TCore
import SwiftUI

struct AssistantCanvas: View {
    let model: AssistantModel
    @State private var viewport: CGFloat = 0
    @State private var tops: [UUID: CGFloat] = [:]
    private static let top: CGFloat = 24
    private static let bottom: CGFloat = 180

    var body: some View {
        FadingScrollView(ground: Palette.window) {
            VStack(alignment: .leading, spacing: 40) {
                AssistantToolbar(model: model)
                ForEach(model.turns) { turn in
                    let isLast = turn.id == model.turns.last?.id
                    AssistantTurnView(model: model, turn: turn, isLast: isLast,
                        toggle: { model.toggleActivity(turn.id) }, retry: { model.retry() },
                        setUp: { MainNavigation.shared.openSetup() })
                        // The last section fills the view, so its question can reach the top.
                        .frame(minHeight: isLast && model.turns.count > 1 ? max(0, viewport - Self.top - Self.bottom) : nil,
                            alignment: .top)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).minY } action: { tops[turn.id] = $0 }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.leading, 32).padding(.trailing, 52).padding(.top, Self.top).padding(.bottom, Self.bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
            .coordinateSpace(.named(Self.space))
            .background(FollowScrollObserver(follow: Binding(get: { model.scroll }, set: { model.scroll = $0 }),
                heldTop: model.scroll.held.flatMap { tops[$0] }.map { $0 - Self.top }))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport = $0 }
        .overlay(alignment: .trailing) {
            if model.turns.count > 1 {
                AssistantMinimap(turns: model.turns) { id in
                    model.scroll = .init(holding: id)
                }
                .padding(.trailing, 14)
            }
        }
        .onDisappear { model.pageDisappeared() }
        .onChange(of: model.turns.last?.state) {
            if let turn = model.turns.last, turn.state == .finished { announce(turn.document.plainText) }
        }
        .onChange(of: model.turns.last?.steps.map { Copy.assistantStep($0) + Copy.assistantDetail($0) }) {
            if let step = model.turns.last?.steps.last { announce(Copy.assistantStep(step) + " " + Copy.assistantDetail(step)) }
        }
    }
    private static let space = "assistant-content"
    private func announce(_ text: String) {
        guard let window = NSApp.keyWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.low.rawValue,
        ])
    }
}

private struct AssistantTurnView: View {
    let model: AssistantModel
    let turn: AssistantTurn
    let isLast: Bool
    let toggle: () -> Void
    let retry: () -> Void
    let setUp: () -> Void
    @State private var questionHover = false
    @State private var unavailableSource = false

    var body: some View {
        let cited = turn.state == .finished ? turn.citedSources : []
        return VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: turn.question).font(Typo.title).foregroundStyle(Palette.text).lineLimit(3)
                .onHover { questionHover = $0 }.tip(verbatim: turn.question, show: questionHover)
            if turn.state == .needsSetup {
                HStack {
                    Text("Set up a language model to ask questions.").foregroundStyle(Palette.secondary)
                    PillButton("Set Up", action: setUp)
                }.padding(.top, 14)
            } else {
                activity.padding(.top, 14)
                if !turn.answer.text.isEmpty {
                    AssistantAnswer(turn: turn, openSource: openSource)
                        .padding(.top, 16)
                }
                ForEach(turn.folderProposals ?? [], id: \.name) { proposal in
                    PillButton("Create folder: \(proposal.name)", icon: "plus") { model.createProposedFolder(proposal, turn: turn.id) }
                }

                if turn.memoryProposal != nil {
                    AssistantPreferenceProposal(model: model, turn: turn).padding(.top, 16)
                }
                if !cited.isEmpty { sources(cited).padding(.top, 20) }
                if turn.state == .stopped { Text("Stopped").font(Typo.caption).foregroundStyle(Palette.muted).padding(.top, 12) }
                if case .failed(let reason) = turn.state {
                    Text(verbatim: reason).font(Typo.caption).foregroundStyle(Palette.danger).padding(.top, 12)
                    if isLast { PillButton("Retry", icon: "refresh", action: retry).padding(.top, 8) }
                }
                if turn.state == .finished || turn.state == .stopped {
                    HStack(spacing: 6) {
                        IconButton("Copy", icon: "copy", tint: Palette.muted) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(turn.copyText, forType: .string)
                        }
                        if isLast { IconButton("Retry", icon: "refresh", tint: Palette.muted, action: retry).focusEffectDisabled() }
                    }.foregroundStyle(Palette.muted).padding(.top, 12).transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if turn.folderBatch != nil { Button("Undo move") { model.undoFiling(turn.id) } }
        }
        .motion(Motion.reveal, value: turn.activityExpanded)
        .motion(Motion.reveal, value: turn.state)
        .alert("Source changed or removed", isPresented: $unavailableSource) { Button("OK", role: .cancel) {} }
    }

    private func openSource(_ source: AssistantSource) {
        Task {
            if await model.sourceIsAvailable(source) {
                MainNavigation.shared.open(.meetings, meeting: source.meeting, utterance: source.utterance)
            } else { unavailableSource = true }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !turn.answer.text.isEmpty {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        Icon("chevron-right", size: 14).rotationEffect(.degrees(turn.activityExpanded ? 90 : 0))
                        Text(verbatim: Copy.assistantActivity(turn)).font(Typo.caption)
                    }.foregroundStyle(Palette.muted)
                }.buttonStyle(.plain).focusEffectDisabled().accessibilityLabel("Show activity")
            }
            if turn.activityExpanded {
                ForEach(turn.steps) { step in
                    AssistantActivityRow(step: step)
                        .modifier(AssistantArrival(model: model, element: .activity(step.id)))
                }
            }
        }
    }
    private func sources(_ cited: [AssistantSource]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources").font(Typo.captionStrong).foregroundStyle(Palette.muted)
            ForEach(Array(cited.enumerated()), id: \.element.id) { index, source in
                Button { openSource(source) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text(verbatim: "\(index + 1)").font(Typo.captionStrong).foregroundStyle(Palette.secondary)
                            .padding(.horizontal, 4).frame(height: 18).background(Palette.tonal, in: RoundedRectangle(cornerRadius: 5))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: source.title).font(Typo.bodyStrong).foregroundStyle(Palette.text).lineLimit(1)
                            Text(source.date, format: .dateTime.year().month().day()).font(Typo.caption).foregroundStyle(Palette.muted)
                            if let quote = source.quote {
                                HStack(alignment: .top, spacing: 6) {
                                    Avatar(name: source.speaker ?? "", isNamed: source.speaker != nil, size: 16)
                                    Text(verbatim: quote).font(Typo.body).foregroundStyle(Palette.secondary).lineLimit(2)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }.card()
                }.buttonStyle(.plain).focusEffectDisabled()
                    .modifier(AssistantArrival(model: model, element: .source(turn: turn.id, id: source.id),
                        delay: Double(index) * 0.06))
            }
        }
    }
}

private struct AssistantActivityRow: View {
    let step: AssistantStep
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch step.state {
                case .running: AssistantRunningDot()
                case .done, .stopped: Icon("check", size: 14).foregroundStyle(Palette.muted)
                case .failed: Icon("alert-triangle", size: 14).foregroundStyle(Palette.danger)
                }
            }.frame(width: 16, height: 20)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if step.kind == .plan && step.state == .running { AssistantThinking() }
                    else { Text(verbatim: Copy.assistantStep(step)).font(Typo.body).foregroundStyle(Palette.secondary) }
                    Text(verbatim: Copy.assistantDetail(step)).font(Typo.body).foregroundStyle(Palette.muted)
                }
                if !step.reasoning.isEmpty { Text(verbatim: step.reasoning).font(Typo.caption).foregroundStyle(Palette.muted).lineLimit(3) }
                if case .failed(let reason) = step.state { Text(verbatim: reason).font(Typo.caption).foregroundStyle(Palette.danger) }
                if step.kind == .read, let result = step.result {
                    AssistantMeetingChips(sources: result.meetings)
                }
            }
        }
    }
}

private struct AssistantRunningDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduce)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
            Circle().fill(Palette.orange).frame(width: 6, height: 6)
                .opacity(reduce ? 1 : 0.35 + 0.65 * (1 - cos(phase * 2 * .pi)) / 2)
        }
    }
}

private struct AssistantThinking: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        Text("Thinking").font(Typo.body).foregroundStyle(Palette.muted)
            .overlay {
                if !reduce {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                        GeometryReader { geometry in
                            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                            LinearGradient(colors: [Palette.text.opacity(0), Palette.text, Palette.text.opacity(0)], startPoint: .leading, endPoint: .trailing)
                                .frame(width: geometry.size.width * 0.6)
                                .offset(x: geometry.size.width * (phase * 1.6 - 0.6))
                        }
                    }.mask(Text("Thinking").font(Typo.body))
                }
            }
    }
}

struct AssistantArrival: ViewModifier {
    let model: AssistantModel
    let element: AssistantShownContent.Element
    let delay: Double
    @State private var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce

    init(model: AssistantModel, element: AssistantShownContent.Element, delay: Double = 0) {
        self.model = model
        self.element = element
        self.delay = delay
        _shown = State(initialValue: model.shownContent.contains(element))
    }

    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).blur(radius: reduce || shown ? 0 : 6)
            .offset(y: reduce || shown ? 0 : 6)
            .motion(.easeOut(duration: 0.35).delay(reduce ? 0 : delay), value: shown)
            .onAppear {
                model.shownContent.insert(element)
                shown = true
            }
    }
}

private struct AssistantMeetingChips: View {
    let sources: [AssistantSource]
    var body: some View {
        GeometryReader { geometry in
            let rows = packed(width: geometry.size.width)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<rows.count, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(rows[row]) { source in
                            Button { MainNavigation.shared.open(.meetings, meeting: source.meeting) } label: {
                                Text(verbatim: source.title).font(Typo.caption).lineLimit(1)
                                    .padding(.horizontal, 8).frame(width: width(source), height: 22)
                                    .background(Palette.tonal, in: Capsule())
                            }.buttonStyle(.plain).focusEffectDisabled().foregroundStyle(Palette.muted)
                        }
                        if row == rows.count - 1 {
                            let omitted = sources.count - rows.flatMap { $0 }.count
                            if omitted > 0 { Text(verbatim: "+\(omitted)").font(Typo.caption).foregroundStyle(Palette.muted) }
                        }
                    }
                }
            }
        }.frame(height: 50)
    }
    private func width(_ source: AssistantSource) -> CGFloat {
        min(160, ceil((source.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width) + 16)
    }
    private func packed(width available: CGFloat) -> [[AssistantSource]] {
        var rows: [[AssistantSource]] = [[]]
        var used: CGFloat = 0
        for source in sources {
            let needed = width(source) + (used == 0 ? 0 : 6)
            let reserve: CGFloat = rows.count == 2 ? 36 : 0
            if used + needed > available - reserve {
                if rows.count == 2 { break }
                rows.append([]); used = 0
            }
            if width(source) > available - (rows.count == 2 ? 36 : 0) { break }
            rows[rows.count - 1].append(source)
            used += width(source) + 6
        }
        return rows
    }
}

/// Keeps the enclosing scroll view pinned to its end while `follow` follows, and tells `follow`
/// when the user scrolls away or back. Placed as the scrolled content's background.
struct FollowScrollObserver: NSViewRepresentable {
    let follow: Binding<AssistantFollowScroll>
    /// Where the held turn should sit at the top of the view, in the scrolled content; nil until
    /// it has been laid out.
    var heldTop: CGFloat?
    func makeNSView(context: Context) -> ScrollProbe {
        let view = ScrollProbe()
        view.follow = follow
        view.heldTop = heldTop
        return view
    }
    func updateNSView(_ view: ScrollProbe, context: Context) {
        view.follow = follow
        view.heldTop = heldTop
        view.scheduleRestore()
    }
}

final class ScrollProbe: NSView {
    var follow: Binding<AssistantFollowScroll>?
    var heldTop: CGFloat?
    private weak var observedScroll: NSScrollView?
    private var lastHeight: CGFloat = 0
    private var lastViewport: CGFloat = 0
    private var lastY: CGFloat = 0
    private var restoring = false
    private var restoreScheduled = false
    private var risenTo: UUID?
    private var rising = false
    /// The user's gesture, its momentum and its rubber-band bounce are theirs: nothing is restored under them.
    private var liveScrolling = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        observedScroll = nil
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.observe() }
    }
    private func observe() {
        guard window != nil, let scroll = enclosingScrollView, let document = scroll.documentView else { return }
        observedScroll = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        document.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(contentResized),
            name: NSView.frameDidChangeNotification, object: document)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollStarted),
            name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollEnded),
            name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        restore()
    }
    @objc private func liveScrollStarted() { liveScrolling = true }
    @objc private func liveScrollEnded() {
        liveScrolling = false
        scheduleRestore()
    }
    func scheduleRestore() {
        guard !restoreScheduled else { return }
        restoreScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restoreScheduled = false
            self.restore()
        }
    }
    private func restore() {
        guard !restoring, !rising, !liveScrolling, let scroll = observedScroll, let follow else { return }
        let held = follow.wrappedValue.held
        // A new section's question is not laid out yet: stay put rather than jump elsewhere first.
        if held != nil && heldTop == nil { return }
        restoring = true
        defer { restoring = false }
        scroll.layoutSubtreeIfNeeded()
        let height = scroll.documentView?.frame.height ?? 0
        let viewport = scroll.contentView.bounds.height
        let insets = scroll.contentInsets
        // The top inset lies under the header: `follow` counts in content shown below it, which
        // starts at -insets.top when the view is at rest at its top.
        let y = follow.wrappedValue.restoredOffset(contentHeight: height + insets.top + insets.bottom, viewportHeight: viewport,
                                                   heldTop: heldTop.map(Double.init)) - insets.top
        lastHeight = height
        lastViewport = viewport
        if let held, held != risenTo {
            risenTo = held
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && abs(scroll.contentView.bounds.minY - y) > 1 {
                rise(scroll, to: y)
                return
            }
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        lastY = scroll.contentView.bounds.minY
    }
    /// Carries the view up to a new section's question, leaving the earlier ones above.
    private func rise(_ scroll: NSScrollView, to y: CGFloat) {
        rising = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
            scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.rising = false
            self.restore()
        }
    }
    @objc private func contentResized() { scheduleRestore() }
    @objc private func scrolled() {
        guard !restoring, !rising, let scroll = observedScroll else { return }
        let height = scroll.documentView?.frame.height ?? 0
        let viewport = scroll.contentView.bounds.height
        let y = scroll.contentView.bounds.minY
        let insets = scroll.contentInsets
        // The clip view pulls the view in when the content shrinks under it; that is not the user.
        let pulledIn = height < lastHeight && y < lastY && abs(y - (height + insets.bottom - viewport)) < 1
        if viewport != lastViewport || pulledIn {
            scheduleRestore()
            return
        }
        // A scroll while the answer grows is still the user's, not a change to undo.
        if y != lastY {
            follow?.wrappedValue.userScrolled(offset: y + insets.top,
                                              bottomDistance: height + insets.bottom - scroll.contentView.bounds.maxY,
                                              towardEnd: y > lastY)
        }
        lastY = y
        if height != lastHeight { scheduleRestore() }
    }
}

/// A rail of lines, one per question, that maps the conversation. Pointing at a line opens a card
/// with that question; clicking it scrolls there.
private struct AssistantMinimap: View {
    let turns: [AssistantTurn]
    let jump: (UUID) -> Void
    @State private var hovered: UUID?

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(turns) { turn in
                Button { jump(turn.id) } label: {
                    Capsule().fill(hovered == turn.id ? Palette.text : Palette.muted)
                        .frame(width: width(turn) + (hovered == turn.id ? 8 : 0), height: 2)
                        .frame(width: 28, height: 14, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).focusEffectDisabled()
                .accessibilityLabel(turn.question)
                .onHover { inside in
                    withAnimation(Motion.reveal) {
                        if inside { hovered = turn.id } else if hovered == turn.id { hovered = nil }
                    }
                }
                .overlay(alignment: .trailing) {
                    if hovered == turn.id { card(turn).offset(x: -36).allowsHitTesting(false) }
                }
                .zIndex(hovered == turn.id ? 1 : 0)
            }
        }
    }

    private func width(_ turn: AssistantTurn) -> CGFloat {
        min(22, max(10, CGFloat(turn.answer.text.count) / 40 + 10))
    }

    private func card(_ turn: AssistantTurn) -> some View {
        let summary = turn.answer.text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { String($0).replacingOccurrences(of: "[*#_`>]|\\[m[^\\]]*\\]", with: "", options: .regularExpression) }
        return VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: turn.question).font(Typo.bodyStrong).foregroundStyle(Palette.text).lineLimit(2)
            if let summary, !summary.isEmpty {
                Text(verbatim: summary).font(Typo.caption).foregroundStyle(Palette.secondary).lineLimit(2)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(width: 220, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hover))
        .shadow(color: Palette.shadow, radius: 10, y: 4)
        .transition(.scale(scale: 0.92, anchor: .trailing).combined(with: .opacity).combined(with: .offset(x: 8)))
    }
}
