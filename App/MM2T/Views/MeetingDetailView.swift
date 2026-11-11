import AppKit
import MM2TApp
import MM2TCore
import SwiftUI
import UniformTypeIdentifiers

struct MeetingDetailView: View {
    let app: AppController
    let back: () -> Void
    @State private var model: MeetingDetailModel
    @State private var confirmReseparate = false
    @State private var showSpeakers = true
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var copied = false

    init(app: AppController, id: MeetingID, back: @escaping () -> Void) {
        self.app = app
        self.back = back
        _model = State(initialValue: app.detail(id, labels: Copy.presentationLabels, playback: TwoTrackPlayer()))
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ScreenHeader(title: Text(verbatim: model.meeting?.metadata.title ?? ""), back: back) {
                if let playback = model.playback {
                    IconButton(playback.isPlaying ? "Pause" : "Play",
                               icon: playback.isPlaying ? "player-pause" : "player-play") {
                        playback.isPlaying ? playback.pause() : playback.play(from: playback.currentTime)
                    }
                }
                IconButton("Rename…", icon: "pencil") {
                    newTitle = model.meeting?.metadata.title ?? ""
                    renaming = true
                }
                .disabled(!model.canEditSpeakers)
                IconButton(copied ? "Copied" : "Copy", icon: copied ? "check" : "copy", isOn: copied, action: copy)
                ExportMenu(model: model)
                IconButton("Speakers", icon: "users", isOn: showSpeakers) { showSpeakers.toggle() }
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    banners
                    Segmented(options: TranscriptView.allCases, selection: $model.selectedView) { Copy.view(for: $0) }
                    if let presentation = model.presentation {
                        TranscriptContent(model: model, presentation: presentation)
                    } else {
                        Spacer()
                    }
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if showSpeakers {
                    SpeakerPanel(model: model)
                        .frame(width: 248)
                        .padding(.trailing, 24)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .motion(Motion.page, value: showSpeakers)
        }
        .task(id: app.queue.revision) { await model.load() }
        .onAppear { DebugSnapshot.detailAppeared(model) }
        .alert("Couldn't change speakers", isPresented: .init(get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } })) {
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $newTitle)
            Button("Save") { Task { await model.rename(to: newTitle) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Separate speakers again?", isPresented: $confirmReseparate) {
            Button("Separate Again", role: .destructive) { Task { await model.reseparate() } }
        } message: {
            if model.reseparationDiscardsEdits {
                Text("Names you assigned and speakers you merged in this meeting will be discarded. The generated views will need regenerating.")
            } else {
                Text("The generated views will need regenerating.")
            }
        }
    }

    /// Puts the view on screen on the clipboard as plain text.
    private func copy() {
        guard let text = model.export(model.selectedView, as: .plainText) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }

    @ViewBuilder private var banners: some View {
        if let job = model.job, job != .completed {
            Banner(icon: "refresh", tone: .info) {
                Text(Copy.job(job))
                Spacer()
                if case .failed = job {
                    PillButton("Retry") { Task { await model.retry() } }
                } else if case .needsSetup = job {
                    PillButton("Open Setup") { WindowOpener.open(WindowID.onboarding) }
                }
            }
        } else if case .failed(let step, let reason) = model.meeting?.status {
            Banner(icon: "alert-triangle", tone: .danger) {
                Text("\(Copy.step(step)) failed: \(reason)")
                Spacer()
                PillButton("Retry") { Task { await model.retry() } }
            }
        } else if case .pending = model.meeting?.status {
            Banner(icon: "refresh", tone: .info) {
                Text("This meeting has not been processed.")
                Spacer()
                PillButton("Process") { Task { await model.retry() } }
            }
        }
        if model.isStale {
            Banner(icon: "refresh", tone: .info) {
                Text("Speakers changed since the generated views were written.")
                Spacer()
                PillButton("Regenerate") { Task { await model.regenerate() } }
                    .disabled(model.isProcessing)
            }
        }
        if let failure = model.separationFailure {
            Banner(icon: "user-question", tone: .danger) {
                Text("Speaker separation failed: \(failure)")
                Spacer()
                PillButton("Separate Again…") { confirmReseparate = true }
                    .disabled(!model.canReseparate)
            }
        }
    }
}

/// A one-line notice above the content with the action that resolves it.
struct Banner<Content: View>: View {
    enum Tone { case info, danger }

    let icon: String
    let tone: Tone
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) {
            Icon(icon, size: 16).foregroundStyle(tone == .danger ? Palette.danger : Palette.orange)
            content
        }
        .font(Typo.body)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(tone == .danger ? Palette.danger.opacity(0.10) : Palette.orangeSoft,
                    in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .entrance(from: .top, distance: 8)
    }
}

struct ExportMenu: View {
    let model: MeetingDetailModel

    var body: some View {
        Menu {
            ForEach(TranscriptView.allCases, id: \.self) { view in
                Section(Copy.view(for: view)) {
                    Button("Markdown…") { save(view, .markdown) }
                    Button("Plain Text…") { save(view, .plainText) }
                    if view == .raw || view == .cleaned { Button("Subtitles (.srt)…") { saveSubtitles(view) } }
                }
            }
        } label: {
            Icon("upload", size: 17).frame(width: 32, height: 32).contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Export")
    }

    private func save(_ view: TranscriptView, _ format: ExportFormat) {
        guard let text = model.export(view, as: format) else { return }
        write(text, view, format == .markdown ? UTType(filenameExtension: "md") ?? .plainText : .plainText)
    }

    private func saveSubtitles(_ view: TranscriptView) {
        guard let text = model.subtitles(view) else { return }
        write(text, view, UTType(filenameExtension: "srt") ?? .plainText)
    }

    private func write(_ text: String, _ view: TranscriptView, _ type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "\(model.meeting?.metadata.title ?? "mm2t") - \(Copy.view(for: view))"
        WindowSharing.exclude(panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
