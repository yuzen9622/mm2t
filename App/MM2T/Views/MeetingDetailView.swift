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
    @State private var showsTranslation = true
    @State private var translationSheet = false
    @State private var waitingForTranslationSettings = false
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
                if model.selectedView == .cleaned, let done = model.translationProgress {
                    ProgressView(value: Double(done), total: Double(model.translationTotal)).frame(width: 64)
                    Text(verbatim: "\(done)/\(model.translationTotal)").font(Typo.caption).monospacedDigit()
                } else if model.selectedView == .cleaned {
                    if model.meeting?.currentTranslation != nil {
                        IconButton(showsTranslation ? "Show original" : "Show translation", icon: "language", isOn: showsTranslation) {
                            showsTranslation.toggle()
                        }
                        .contextMenu {
                            Button("Replace translation") { translationSheet = true }.disabled(!model.canEditSpeakers)
                        }
                    } else {
                        IconButton("Translate transcript", icon: "language") { translationSheet = true }
                            .disabled(!model.canEditSpeakers || model.presentation?.cleaned?.isEmpty != false)
                    }
                }
                ExportMenu(model: model)
                IconButton("Speakers", icon: "users", isOn: showSpeakers) { showSpeakers.toggle() }
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    banners
                    Segmented(options: TranscriptView.allCases, selection: $model.selectedView) { Copy.view(for: $0) }
                    if let presentation = model.presentation {
                        TranscriptContent(model: model, presentation: presentation, playhead: playhead, showsTranslation: showsTranslation, todoKey: todoKey)
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
        .disabled(translationSheet)
        .accessibilityHidden(translationSheet)
        .overlay {
            if translationSheet {
                ZStack {
                    Color.black.opacity(0.28).onTapGesture { translationSheet = false }
                    TranscriptTranslationSheet(app: app, replacing: model.meeting?.translation != nil, cancel: { translationSheet = false }, openSettings: {
                        translationSheet = false
                        waitingForTranslationSettings = true
                        MainNavigation.shared.settingsSection = .general
                        MainNavigation.shared.settingsOpen = true
                    }) { target, engine in
                        translationSheet = false
                        Task {
                            await model.translate(target: target, engine: engine, catalog: app.translationCatalog)
                            if model.translationError == nil { showsTranslation = true }
                        }
                    }
                }
                .dropdownLayer()
            }
        }
        .onChange(of: MainNavigation.shared.settingsOpen) { _, open in
            guard !open, waitingForTranslationSettings else { return }
            waitingForTranslationSettings = false
            translationSheet = app.settings.settings.translationEnabled
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
            ForEach(TranscriptView.allCases, id: \.self) { view in
                Section(Copy.view(for: view)) {
                    if view == .cleaned, model.meeting?.currentTranslation != nil { Toggle("Include translation", isOn: $includeTranslation) }
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
    let replacing: Bool
    let cancel: () -> Void
    let openSettings: () -> Void
    let start: (CaptionTarget, CaptionEngine) -> Void
    @State private var targets: [CaptionTarget] = []
    @State private var target: CaptionTarget?

    @State private var appleLanguages: [AppleCaptionLanguage] = []
    @State private var revision = 0
    @State private var preparing = false
    @State private var downloadFailed = false

    private var enabled: Bool { app.settings.settings.translationEnabled }
    private var engine: CaptionEngine { app.settings.settings.captionEngine }
    private var missingPack: AppleCaptionLanguage? {
        appleLanguages.first { engine == .apple && $0.target == target && !$0.missingSources.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(enabled ? LocalizedStringKey("Translate transcript") : "Set up translation model").font(Typo.title)
            if enabled {
                HStack {
                    Text("Target language")
                    Spacer()
                    Dropdown(label: "Target language", options: targets.map {
                        DropdownOption(id: Optional($0), leading: $0.flag, title: $0.name)
                    }, selection: $target, placeholder: String(localized: "Checking…"))
                    .disabled(preparing)
                }
                if let missingPack, #available(macOS 26, *) {
                    AppleModelDownload(language: missingPack) { revision += 1 }.id(missingPack.identifier)
                }
            }
            if downloadFailed { Text("Couldn't download the translation model.").font(Typo.caption).foregroundStyle(Palette.danger) }
            HStack(spacing: 8) {
                if preparing { ProgressView().controlSize(.small) }
                Spacer()
                PillButton("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                if enabled {
                    PillButton(replacing ? "Replace translation" : "Translate transcript", kind: .primary) { preparing = true }
                        .keyboardShortcut(.defaultAction).disabled(preparing || target == nil || missingPack != nil)
                } else {
                    PillButton("Open Settings", kind: .primary, action: openSettings).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22).frame(width: 340)
        .background(Palette.window, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .shadow(color: Palette.shadow, radius: 30, y: 12)
        .task(id: enabled ? engine : nil) { await loadTargets() }
        .task(id: revision) { if revision > 0 { await loadTargets() } }
        .task(id: preparing) {
            guard preparing, enabled, let target else { return }
            let chosen = engine
            let ready = await app.setup.prepareTranscriptModel(engine: chosen, target: target)
            guard !Task.isCancelled else { return }
            preparing = false
            downloadFailed = !ready
            if ready, enabled, engine == chosen { start(target, chosen) }
        }
    }

    private func loadTargets() async {
        let preferred = target ?? app.settings.settings.captionTranslation.target ?? .english
        targets = []
        target = nil
        appleLanguages = []
        downloadFailed = false
        guard enabled else { return }
        switch engine {
        case .apple:
            let languages = await AppleCaptionTranslator.languages()
            guard !Task.isCancelled else { return }
            appleLanguages = languages
            targets = languages.map(\.target)
        case .firefox: targets = CaptionTarget.all
        case .hyMT2: targets = CaptionTarget.hyTargets
        }
        target = targets.first(where: { $0 == preferred }) ?? targets.first
    }
}
