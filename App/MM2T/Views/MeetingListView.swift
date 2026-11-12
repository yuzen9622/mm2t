import MM2TApp
import MM2TCore
import SwiftUI

struct MeetingListView: View {
    let app: AppController
    let open: (MeetingID) -> Void
    @State private var pendingDelete: MeetingRow?
    @Environment(\.openWindow) private var openWindow

    private var model: MeetingListModel { app.meetings }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ScreenHeader {
                SearchField(text: $model.query).frame(width: 220)
                PillButton("Start Recording", icon: "microphone", kind: .primary) {
                    Task { await app.capture.startNow(title: String(localized: "Recording")) }
                }
                .disabled(app.capture.state != .idle)
            }
            if model.rows.isEmpty {
                EmptyState(icon: "messages", title: model.query.isEmpty ? "No meetings yet" : "No results")
                    .transition(.opacity)
            } else {
                FadingScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.rows) { row in
                            MeetingCard(row: row, isRecovered: app.recovered.contains(row.id),
                                        process: { Task { await process(row) } },
                                        setUp: { openWindow(id: WindowID.onboarding) })
                                .onTapGesture { if row.status == .completed { open(row.id) } }
                                .contextMenu {
                                    Button("Delete…", role: .destructive) { pendingDelete = row }
                                        .disabled(app.queue.isBusy(row.id))
                                }
                                .transition(.asymmetric(insertion: .offset(y: 10).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .motion(Motion.page, value: model.rows.map(\.id))
                }
            }
        }
        .task(id: model.query) { await model.reload() }
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
    let row: MeetingRow
    let isRecovered: Bool
    let process: () -> Void
    let setUp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title).font(Typo.heading).lineLimit(1)
                Spacer()
                Text("\(row.startedAt, format: .dateTime.month().day().hour().minute()) · \(Duration.seconds(row.duration), format: .units(allowed: [.hours, .minutes], width: .abbreviated))")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.secondary)
                    .monospacedDigit()
            }
            state
        }
        .card(lifts: row.status == .completed)
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
