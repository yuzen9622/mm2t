import AppKit
import MM2TApp
import MM2TCore
import SwiftUI

struct AssistantCanvas: View {
    let model: AssistantModel
    @State private var follow = AssistantFollowScroll()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollViewReader { proxy in
            FadingScrollView(ground: Palette.window) {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 40) {
                        ForEach(model.turns) { turn in
                            AssistantTurnView(turn: turn, isLast: turn.id == model.turns.last?.id,
                                toggle: { model.toggleActivity(turn.id) }, retry: { model.retry() },
                                setUp: { openWindow(id: WindowID.onboarding) })
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 180)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("assistant-bottom")
                }
                .background(AssistantScrollObserver { follow.userScrolled(bottomDistance: $0) })
            }
            .onChange(of: model.turns.count) { follow.sent(); proxy.scrollTo("assistant-bottom", anchor: .bottom) }
            .onChange(of: model.turns.last?.answer.text) {
                if follow.follows { proxy.scrollTo("assistant-bottom", anchor: .bottom) }
            }
            .onChange(of: model.turns.last?.state) {
                if follow.follows { proxy.scrollTo("assistant-bottom", anchor: .bottom) }
                if let turn = model.turns.last, turn.state == .finished { announce(turn.document.plainText) }
            }
            .onChange(of: model.turns.last?.steps.map { Copy.assistantStep($0) + Copy.assistantDetail($0) }) {
                if let step = model.turns.last?.steps.last { announce(Copy.assistantStep(step) + " " + Copy.assistantDetail(step)) }
            }
        }
    }
    private func announce(_ text: String) {
        guard let window = NSApp.keyWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.low.rawValue,
        ])
    }
}

private struct AssistantTurnView: View {
    let turn: AssistantTurn
    let isLast: Bool
    let toggle: () -> Void
    let retry: () -> Void
    let setUp: () -> Void
    @State private var questionHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: turn.question).font(Typo.title).foregroundStyle(Palette.text).lineLimit(3)
                .onHover { questionHover = $0 }.tip(verbatim: turn.question, show: questionHover)
            if turn.state == .needsSetup {
                HStack {
                    Text("Set up a language model to ask questions.").foregroundStyle(Palette.secondary)
                    PillButton("Set Up", action: setUp)
                }.padding(.top, 14)
            } else {
                activity.padding(.top, 14)
                if !turn.answer.text.isEmpty { AssistantAnswer(turn: turn).padding(.top, 16) }
                if turn.state == .finished && !turn.citedSources.isEmpty { sources.padding(.top, 20) }
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
        .motion(Motion.reveal, value: turn.activityExpanded)
        .motion(Motion.reveal, value: turn.state)
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
                ForEach(turn.steps) { step in AssistantActivityRow(step: step).modifier(AssistantArrival()) }
            }
        }
    }
    private var sources: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources").font(Typo.captionStrong).foregroundStyle(Palette.muted)
            ForEach(Array(turn.citedSources.enumerated()), id: \.element.id) { index, source in
                Button { MainNavigation.shared.open(.meetings, meeting: source.meeting, utterance: source.utterance) } label: {
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
                    .modifier(AssistantArrival(delay: Double(index) * 0.06))
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
    var delay = 0.0
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).blur(radius: reduce || shown ? 0 : 6)
            .offset(y: reduce || shown ? 0 : 6)
            .motion(.easeOut(duration: 0.35).delay(reduce ? 0 : delay), value: shown)
            .onAppear { shown = true }
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

private struct AssistantScrollObserver: NSViewRepresentable {
    let changed: (Double) -> Void
    func makeNSView(context: Context) -> ScrollProbe { let view = ScrollProbe(); view.changed = changed; return view }
    func updateNSView(_ view: ScrollProbe, context: Context) { view.changed = changed }
}

private final class ScrollProbe: NSView {
    var changed: (Double) -> Void = { _ in }
    private weak var observedScroll: NSScrollView?
    private var lastHeight: CGFloat = 0
    private var lastY: CGFloat = 0
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        observedScroll = nil
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.observe() }
    }
    private func observe() {
        guard let scroll = enclosingScrollView else { return }
        lastHeight = scroll.documentView?.frame.height ?? 0
        lastY = scroll.contentView.bounds.minY
        scroll.contentView.postsBoundsChangedNotifications = true
        observedScroll = scroll
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    @objc private func scrolled() {
        guard let scroll = observedScroll else { return }
        let height = scroll.documentView?.frame.height ?? 0
        let y = scroll.contentView.bounds.minY
        if height == lastHeight && y != lastY {
            changed(Double(height - scroll.contentView.bounds.maxY))
        }
        lastHeight = height; lastY = y
    }
}
