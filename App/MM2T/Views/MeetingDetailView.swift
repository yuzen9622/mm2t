import AppKit
import MM2TApp
import MM2TCore
import MM2TLocal
import SwiftUI
import UniformTypeIdentifiers

struct MeetingDetailView: View {
    let app: AppController
    let back: () -> Void
    let todoKey: String?
    let utterance: UtteranceID?
    @State private var openedAtUtterance = false
    @State private var model: MeetingDetailModel
    @State private var confirmReseparate = false
    @State private var showSpeakers = true
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var translationSheet = false
    @State private var copied = false
    @State private var playhead = Playhead()
    @State private var confirmRegenerate = false

    init(app: AppController, id: MeetingID, utterance: UtteranceID? = nil, todoKey: String? = nil, back: @escaping () -> Void) {
        self.app = app
        self.utterance = utterance
        self.todoKey = todoKey
        self.back = back
        _model = State(initialValue: app.detail(id, labels: Copy.presentationLabels, playback: TwoTrackPlayer()))
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ScreenHeader(title: Text(verbatim: model.meeting?.metadata.title ?? ""), back: back) {
                IconButton("Rename…", icon: "pencil") {
                    newTitle = model.meeting?.metadata.title ?? ""
                    renaming = true
                }
                .disabled(!model.canEditSpeakers)
                IconButton("Regenerate Views…", icon: "sparkles") { confirmRegenerate = true }
                    .disabled(!model.canEditSpeakers)
                IconButton(copied ? "Copied" : "Copy", icon: copied ? "check" : "copy", isOn: copied, action: copy)
                if let done = model.translationProgress {
                    ProgressView(value: Double(done), total: Double(model.translationTotal)).frame(width: 64)
                    Text(verbatim: "\(done)/\(model.translationTotal)").font(Typo.caption).monospacedDigit()
                } else if model.selectedView == .raw || model.selectedView == .cleaned {
                    Button { translationSheet = true } label: { Image(systemName: "translate").accessibilityLabel(Text("Translate transcript")) }
                        .buttonStyle(.plain).help("Translate transcript")
                        .disabled(!model.canEditSpeakers || model.presentation?.cleaned?.isEmpty != false)
                }
                ExportMenu(model: model)
                IconButton("Speakers", icon: "users", isOn: showSpeakers) { showSpeakers.toggle() }
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    banners
                    Segmented(options: TranscriptView.allCases, selection: $model.selectedView) { Copy.view(for: $0) }
                    if let presentation = model.presentation {
                        TranscriptContent(model: model, presentation: presentation, playhead: playhead, todoKey: todoKey)
                            .overlay(alignment: .bottom) {
                                if let playback = model.playback {
                                    TransportBar(playhead: playhead, status: playback.status, toggle: {
                                        playback.isPlaying ? playback.pause() : playback.play(from: playback.currentTime)
                                        sample()
                                    }, seek: { time in
                                        playback.seek(to: time)
                                        sample()
                                    })
                                    .frame(maxWidth: 560)
                                    .padding(.bottom, 16)
                                }
                            }
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
        .task(id: app.queue.revision) {
            if !openedAtUtterance, todoKey != nil { model.selectedView = .summary }
            await model.load(at: openedAtUtterance ? nil : utterance)
            if !Task.isCancelled { openedAtUtterance = true }
            sample()
        }
        // Samples the playhead while audio plays; AVAudioPlayer has no time callback of its own.
        // Twenty times a second keeps the character being spoken brightening smoothly.
        .task(id: model.playback?.isPlaying ?? false) {
            while !Task.isCancelled {
                sample()
                guard playhead.isPlaying else { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        .onChange(of: model.playback?.duration) { sample() }
        .onChange(of: model.playback?.status) { sample() }
        .sheet(isPresented: $translationSheet) {
            if let rows = model.presentation?.cleaned {
                TranscriptTranslationSheet(app: app, rows: rows, replacing: model.meeting?.translation != nil) { selected, target in
                    translationSheet = false
                    Task { await model.translate(selected, target: target, engine: app.settings.settings.captionEngine, catalog: app.translationCatalog) }
                }
            }
        }
        .alert("Couldn't translate transcript", isPresented: .init(get: { model.translationError != nil }, set: { if !$0 { model.translationError = nil } })) {
            Button("OK") { model.translationError = nil }
        } message: { Text(model.translationError ?? "") }
        .onDisappear { model.playback?.pause() }
        .alert("Couldn't change speakers", isPresented: .init(get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } })) {
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $newTitle)
            Button("Save") { Task { await model.rename(to: newTitle) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Regenerate the cleaned transcript, summary and notes?", isPresented: $confirmRegenerate) {
            Button("Regenerate") { Task { await model.regenerate() } }
        } message: {
            Text("Corrections you made to the cleaned transcript will be replaced.")
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

    private func sample() {
        guard let playback = model.playback else { return }
        // AVAudioPlayer stops at the end without saying so.
        if playback.isPlaying, playback.duration > 0, playback.currentTime >= playback.duration - 0.05 {
            playback.pause()
        }
        playhead.sample(time: playback.currentTime, duration: playback.duration, isPlaying: playback.isPlaying)
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
                } else if job.isActive {
                    PillButton("Cancel") { model.cancelProcessing() }
                } else if case .needsSetup = job {
                    PillButton("Open Setup") { MainNavigation.shared.openSetup() }
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
    @State private var includeTranslation = false
    let model: MeetingDetailModel

    var body: some View {
        Menu {
            if model.meeting?.translation != nil {
                Toggle("Include translation", isOn: $includeTranslation)
            }
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
        guard let text = model.export(view, as: format, includeTranslation: includeTranslation) else { return }
        write(text, view, format == .markdown ? UTType(filenameExtension: "md") ?? .plainText : .plainText)
    }

    private func saveSubtitles(_ view: TranscriptView) {
        guard let text = model.subtitles(view, includeTranslation: includeTranslation) else { return }
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

private struct TranscriptTranslationSheet: View {
    let app: AppController
    let rows: [SourcedRow]
    let replacing: Bool
    let start: (Set<Int>, CaptionTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var targets: [CaptionTarget] = []
    @State private var target: CaptionTarget?
    @State private var selected: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Translate transcript").font(Typo.heading)
            Picker("Target language", selection: $target) {
                ForEach(targets) { Text(verbatim: $0.name).tag(Optional($0)) }
            }
            Toggle("Select all", isOn: Binding(get: { selected.count == rows.count }, set: { selected = $0 ? Set(rows.indices) : [] }))
            List(Array(rows.enumerated()), id: \.element.id) { index, row in
                Toggle(isOn: Binding(get: { selected.contains(index) }, set: { if $0 { selected.insert(index) } else { selected.remove(index) } })) {
                    Text(verbatim: row.text)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(replacing ? "Replace translation" : "Translate transcript") { if let target { start(selected, target) } }
                    .keyboardShortcut(.defaultAction).disabled(target == nil || selected.isEmpty)
            }
        }
        .padding(20).frame(width: 480, height: 410)
        .onAppear { selected = Set(rows.indices) }
        .task(id: app.settings.settings.captionEngine) {
            switch app.settings.settings.captionEngine {
            case .apple: targets = await AppleCaptionTranslator.languages().map(\.target)
            case .firefox: targets = CaptionTarget.all
            case .hyMT2: targets = CaptionTarget.hyTargets
            }
            let preferred = app.settings.settings.captionTranslation.target ?? .english
            target = targets.first(where: { $0 == preferred }) ?? targets.first
        }
    }
}
