import MM2TApp
import MM2TCore
import SwiftUI

struct MeetingDrag { let id: MeetingID; let title: String }
enum FilingTarget: Hashable { case folder(UUID?), composer }
struct FilingBounds: PreferenceKey {
    static var defaultValue: [FilingTarget: CGRect] { [:] }
    static func reduce(value: inout [FilingTarget: CGRect], nextValue: () -> [FilingTarget: CGRect]) { value.merge(nextValue()) { _, new in new } }
}
extension View {
    func filingTarget(_ target: FilingTarget) -> some View {
        background(GeometryReader { proxy in Color.clear.preference(key: FilingBounds.self, value: [target: proxy.frame(in: .named("meeting-filing"))]) })
    }
}
@MainActor @Observable final class FilingDragState {
    var item: MeetingDrag?
    var hovered: FilingTarget?
    var received: FilingTarget?
    private var receipt: Task<Void, Never>?
    func acknowledge(_ target: FilingTarget) {
        receipt?.cancel(); received = target
        receipt = Task { try? await Task.sleep(for: .milliseconds(480)); if !Task.isCancelled { received = nil } }
    }
    var location = CGPoint.zero
    var bounds: [FilingTarget: CGRect] = [:]
    var insertReference: ((MeetingDrag) -> Void)?
}

struct MeetingListView: View {
    @Environment(FilingDragState.self) private var drag
    let app: AppController
    let open: (MeetingID) -> Void
    @State private var pendingDelete: MeetingRow?
    let assistant: AssistantModel
    @State private var layout: AssistantLayoutState
    @Environment(\.accessibilityReduceMotion) private var reduce

    init(app: AppController, assistant: AssistantModel, open: @escaping (MeetingID) -> Void) {
        self.app = app
        self.assistant = assistant
        self.open = open
        _layout = State(initialValue: AssistantLayoutState(active: assistant.isActive))
    }

    private var model: MeetingListModel { app.meetings }

    private var visibleRows: [MeetingRow] { model.rows.filter { app.folders.folder(of: $0.id) == app.folders.selected } }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                if assistant.isActive {
                    PillButton("Back to list", icon: "chevron-left") { assistant.isActive = false }
                }
                SearchPaletteTrigger { MainNavigation.shared.searchOpen = true }
                PillButton("Start Recording", icon: "microphone", kind: .primary) {
                    Task { await app.capture.startNow(title: String(localized: "Recording")) }
                }
                .disabled(app.capture.state != .idle)
            }
            GeometryReader { geometry in
                let rail = layout.active && geometry.size.width >= 760
                let canvasWidth = geometry.size.width - (rail ? 304 : 0)
                ZStack(alignment: .trailing) {
                    if layout.active {
                        AssistantCanvas(model: assistant)
                            .frame(width: canvasWidth)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .opacity(layout.canvasShown ? 1 : 0)
                            .offset(y: reduce || layout.canvasShown ? 0 : 16)
                            .motion(Motion.page, value: layout.canvasShown)
                    }
                    meetingList(compact: layout.active)
                        .id(app.folders.selected).entrance(from: .bottom, distance: 8)
                        .frame(width: layout.active ? 280 : geometry.size.width)
                        .opacity(layout.active && !rail ? 0 : 1)
                        .allowsHitTesting(!layout.active || rail)
                        .accessibilityHidden(layout.active && !rail)
                }
                .overlay(alignment: .bottomLeading) {
                    AssistantComposer(model: assistant)
                        .frame(maxWidth: 720)
                        .padding(.horizontal, 24)
                        .frame(width: layout.active ? canvasWidth : geometry.size.width)
                        .padding(.bottom, 20)
                }
                .motion(Motion.page, value: app.folders.selected)
                .motion(Motion.page, value: layout.active)
                .motion(Motion.page, value: rail)
                .transaction { if reduce { $0.animation = nil } }
                .opacity(layout.visible ? 1 : 0)
                .motion(.easeOut(duration: 0.12), value: layout.visible)
            }
        }
        .task(id: assistant.isActive) {
            await layout.transition(active: assistant.isActive, reduced: reduce)
        }
        .task(id: app.queue.revision) { await model.reload() }
        .confirmationDialog("Delete this meeting?", isPresented: .init(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { row in
            Button("Delete Recording and Transcript", role: .destructive) {
                Task { await model.delete(row.id) }
            }
        } message: { _ in
            Text("Both audio tracks and every generated view are removed from this Mac.")
        }
    }

    private func meetingList(compact: Bool) -> some View {
        FadingScrollView(ground: Palette.window) {
            LazyVStack(alignment: .leading, spacing: compact ? 0 : 10) {
                if compact {
                    Text("Meetings").font(Typo.captionStrong).foregroundStyle(Palette.muted).padding(.bottom, 12)
                }
                if visibleRows.isEmpty { EmptyState(icon: "messages", title: "No meetings yet") }
                ForEach(compact ? AssistantRail.ordered(visibleRows, cited: assistant.citedMeetings) : visibleRows) { row in
                    if compact && assistant.citedMeetings.contains(row.id) && row.id == AssistantRail.ordered(visibleRows, cited: assistant.citedMeetings).first?.id {
                        Text("Cited").font(Typo.captionStrong).foregroundStyle(Palette.muted).padding(.bottom, 4)
                    }
                    MeetingCard(row: row, isRecovered: app.recovered.contains(row.id), compact: compact,
                                cited: assistant.citedMeetings.contains(row.id),
                                process: { Task { await process(row) } }, setUp: { MainNavigation.shared.openSetup() })
                        .contentShape(Rectangle())
                        .simultaneousGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("meeting-filing"))
                            .onChanged { value in
                                drag.item = MeetingDrag(id: row.id, title: row.title); drag.location = value.location
                                let target = drag.bounds.first { $0.value.contains(value.location) }?.key
                                drag.hovered = target == .folder(app.folders.folder(of: row.id)) ? nil : target
                            }.onEnded { value in
                                defer { drag.item = nil; drag.hovered = nil }
                                guard let item = drag.item, let target = drag.bounds.first(where: { $0.value.contains(value.location) })?.key else { return }
                                switch target {
                                case .composer: drag.insertReference?(item)
                                case .folder(let folder): if app.folders.move([row.id: folder], origin: .manual) { drag.acknowledge(target) }
                                }
                            })
                        .onTapGesture { if compact || row.status == .completed { open(row.id) } }
                        .accessibilityAction { open(row.id) }
                        .focusable().focusEffectDisabled()
                        .onKeyPress(.return) { open(row.id); return .handled }
                        .contextMenu {
                            Button("Delete…", role: .destructive) { pendingDelete = row }.disabled(app.queue.isBusy(row.id))
                        }
                }
            }
            .padding(.horizontal, compact ? 0 : 24).padding(.bottom, 180)
            .motion(Motion.select, value: assistant.citedMeetings)
            .motion(Motion.page, value: visibleRows.map(\.id))
        }
    }

    private func process(_ row: MeetingRow) async {
        if app.recovered.contains(row.id) {
            await app.processRecovered(row.id)
        } else {
            await model.process(row.id)
        }
    }
}

/// Title with the time to its right, the summary's preview below, then who spoke. While a meeting
/// is not finished the preview line carries its state instead.
struct MeetingCard: View {
    @Environment(\.locale) private var locale
    let row: MeetingRow
    let isRecovered: Bool
    var compact = false
    var cited = false
    let process: () -> Void
    let setUp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack(alignment: .firstTextBaseline) {
                if compact && cited { Circle().fill(Palette.orange).frame(width: 6, height: 6) }
                Text(row.title).font(compact ? Typo.bodyStrong : Typo.heading).lineLimit(1)
                if !compact {
                    Spacer()
                    Text("\(row.startedAt, format: .dateTime.month().day().hour().minute()) · \(MeetingPresentation.duration(row.duration, locale: locale))")
                        .font(Typo.caption).foregroundStyle(Palette.secondary).monospacedDigit()
                }
            }
            if compact {
                Text(row.startedAt, format: .dateTime.month().day()).font(Typo.caption).foregroundStyle(Palette.muted)
            } else { state }
        }
        .card(lifts: row.status == .completed, compact: compact)
        .motion(Motion.page, value: compact)
        .motion(Motion.reveal, value: row.status)
    }

    @ViewBuilder private var state: some View {
        switch row.status {
        case .completed:
            if let headline = row.headline {
                Text(headline).foregroundStyle(Palette.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            AvatarStack(people: row.participants.map { .init(id: $0.id.rawValue, name: $0.name, isNamed: $0.isNamed) })
        case .processing(let step):
            Text(Copy.step(step)).font(Typo.bodyStrong).foregroundStyle(Palette.orange)
                .contentTransition(.opacity)
            ProgressLine(fraction: Self.fraction(step))
        case .failed(let reason):
            HStack(alignment: .center, spacing: 12) {
                Icon("alert-triangle", size: 16).foregroundStyle(Palette.danger)
                Text(reason).foregroundStyle(Palette.danger).lineLimit(2)
                Spacer()
                PillButton("Retry", icon: "refresh", action: process)
            }
        case .needsSetup:
            HStack {
                Text("Waiting for setup").foregroundStyle(Palette.secondary)
                Spacer()
                PillButton("Set Up", action: setUp)
            }
        case .notProcessed:
            HStack {
                Text(isRecovered ? "Recovered recording" : "Not processed").foregroundStyle(Palette.secondary)
                Spacer()
                PillButton("Process", action: process)
            }
        }
    }

    /// Steps are unequal in duration, so this only shows which step of eight is running.
    static func fraction(_ step: ProcessingStep?) -> Double {
        guard let step, let index = ProcessingStep.allCases.firstIndex(of: step) else { return 0.03 }
        return (Double(index) + 0.5) / Double(ProcessingStep.allCases.count)
    }
}
