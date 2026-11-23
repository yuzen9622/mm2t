import MM2TApp
import MM2TProviders
import SwiftUI

extension ModelService {
    var title: String {
        switch self {
        case .mm2t: String(localized: "mm2t plan")
        case .elevenLabs: "ElevenLabs"
        case .gemini: "Gemini"
        case .openAICompatible: String(localized: "OpenAI-compatible server")
        case .transcriptionServer: String(localized: "Transcription server")
        }
    }

    var icon: String {
        switch self {
        case .mm2t: "sparkles"
        case .elevenLabs: "wave-sine"
        case .gemini: "brand-google"
        case .openAICompatible, .transcriptionServer: "server"
        }
    }

    var setupAction: LocalizedStringKey {
        switch self {
        case .mm2t: "Sign in"
        case .elevenLabs, .gemini: "Add key"
        case .openAICompatible, .transcriptionServer: "Set up"
        }
    }
}

var planName: String { String(localized: "Free") }

struct ModelsServicesPage: View {
    let app: AppController
    @State private var editor: ModelService?
    @State private var picker: Job?
    @State private var modelCache: ModelList?
    @State private var loadingModels = false
    @State private var listingFailed = false

    private enum Job: Hashable { case transcription, summaries }
    private struct ModelList {
        let endpoint: URL
        let models: [String]
    }

    private var settings: AppSettings { app.settings.settings }
    private var cachedModels: [String]? {
        guard let modelCache, modelCache.endpoint == settings.openAIBaseURL else { return nil }
        return modelCache.models
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !app.setup.issues.isEmpty {
                Panel(title: "Still needed") {
                    ForEach(app.setup.issues, id: \.self) { issue in
                        HStack(spacing: 8) {
                            Icon("alert-triangle", size: 15).foregroundStyle(Palette.orange)
                            Text(verbatim: Copy.issue(issue))
                            Spacer(minLength: 4)
                            if let service = issue.service {
                                PillButton(service.setupAction) { editor = service }
                            } else {
                                PillButton("Download") { Task { await app.setup.downloadModels() } }
                                    .disabled(app.setup.models == .downloaded || {
                                        if case .downloading = app.setup.models { return true }
                                        return false
                                    }())
                            }
                        }
                    }
                }
            }
            Panel(title: "Models") {
                VStack(spacing: 0) {
                    jobRow(.transcription, title: "Post-meeting transcription", icon: "microphone", choice: transcriptionLabel)
                    jobRow(.summaries, title: "Summaries and assistant", icon: "sparkles", choice: summaryLabel)
                }
            }
            Panel(title: "Services") {
                VStack(spacing: 0) {
                    ForEach(ModelService.allCases) { service in serviceRow(service) }
                }
            }
        }
        .sheet(item: $editor) { service in
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(verbatim: service.title).font(Typo.title)
                    Spacer()
                    PillButton("Done") { editor = nil }.keyboardShortcut(.cancelAction)
                }
                ServiceEditor(app: app, service: service) { endpoint, models in
                    modelCache = models.map { ModelList(endpoint: endpoint, models: $0) }
                }
                .card()
            }
            .padding(20)
            .frame(width: 420)
            .background(Palette.panel)
            .foregroundStyle(Palette.text)
            .font(Typo.body)
        }
    }

    private var transcriptionLabel: String {
        switch settings.transcriptionService {
        case .mm2t: "mm2t"
        case .elevenLabs: "ElevenLabs"
        case .server: settings.selfHostedURL?.host() ?? ModelService.transcriptionServer.title
        }
    }

    private var summaryLabel: String {
        switch settings.summaryService {
        case .mm2t: "mm2t"
        case .gemini: "Gemini"
        case .openAICompatible: settings.openAIModel.isEmpty ? ModelService.openAICompatible.title : settings.openAIModel
        }
    }

    private func jobRow(_ job: Job, title: LocalizedStringKey, icon: String, choice: String) -> some View {
        HStack(spacing: 10) {
            tile(icon)
            Text(title).font(Typo.bodyStrong)
            Spacer(minLength: 8)
            Button { picker = job } label: {
                HStack(spacing: 6) {
                    Text(verbatim: choice).lineLimit(1).truncationMode(.middle)
                    Icon("selector", size: 13).foregroundStyle(Palette.secondary)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Palette.tonal, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.muted.opacity(0.5), lineWidth: 0.5) }
            }
            .buttonStyle(Pressable())
            .accessibilityLabel(Text(title))
            .accessibilityValue(choice)
            .popover(isPresented: Binding(get: { picker == job }, set: { if !$0, picker == job { picker = nil } }), arrowEdge: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if job == .transcription { transcriptionChoices } else { summaryChoices }
                    }
                    .padding(8)
                }
                .defaultScrollAnchor(.top)
                .frame(width: 260, height: menuHeight(job))
                .background(Palette.panel)
                .dropdownLayer()
                .task(id: settings.openAIBaseURL) { if job == .summaries { await fetchModels() } }
            }
        }
        .frame(height: 44)
    }

    private func menuHeight(_ job: Job) -> CGFloat {
        guard job == .summaries else { return 190 }
        return min(360, 170 + CGFloat(max(1, openAIChoices.count)) * 30 + (loadingModels || listingFailed ? 28 : 0))
    }

    private var transcriptionChoices: some View {
        ForEach(TranscriptionService.allCases, id: \.self) { source in
            let service = source.connection
            menuGroup(service) {
                switch source {
                case .mm2t: option("mm2t", selected: settings.transcriptionService == source) { choose(source) }
                case .elevenLabs: option("Scribe", selected: settings.transcriptionService == source) { choose(source) }
                case .server:
                    option(settings.selfHostedURL?.host() ?? service.title, selected: settings.transcriptionService == source) { choose(source) }
                }
            }
        }
    }

    private var summaryChoices: some View {
        ForEach(SummaryService.allCases, id: \.self) { source in
            menuGroup(source.connection) {
                switch source {
                case .mm2t: option("mm2t", selected: settings.summaryService == source) { choose(source) }
                case .gemini: option("Gemini", selected: settings.summaryService == source) { choose(source) }
                case .openAICompatible:
                    ForEach(openAIChoices, id: \.self) { model in
                        option(model, selected: settings.summaryService == source && settings.openAIModel == model) {
                            var updated = settings
                            updated.openAIModel = model
                            updated.summaryService = source
                            app.settings.settings = updated
                            app.setup.recheck()
                            picker = nil
                        }
                    }
                    if loadingModels { ProgressView().controlSize(.mini).padding(.horizontal, 8) }
                    if listingFailed || (!loadingModels && openAIChoices.isEmpty) { setupOption(source.connection) }
                }
            }
        }
    }

    private var openAIChoices: [String] {
        var choices = cachedModels ?? []
        let saved = settings.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty, !choices.contains(saved) { choices.insert(saved, at: 0) }
        return choices
    }

    private func menuGroup<Content: View>(_ service: ModelService, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: service.title).font(Typo.caption).foregroundStyle(Palette.secondary).padding(.horizontal, 8)
            if configured(service) { content() } else { setupOption(service) }
        }
    }

    private func setupOption(_ service: ModelService) -> some View {
        menuButton(Text(service.setupAction), selected: false, secondary: true) {
            picker = nil
            editor = service
        }
    }

    private func option(_ name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        menuButton(Text(verbatim: name), selected: selected, secondary: false, action: action)
            .help(name)
    }

    private func menuButton(_ label: Text, selected: Bool, secondary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                label.lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if selected { Icon("check", size: 15).foregroundStyle(Palette.orange) }
            }
            .foregroundStyle(secondary ? Palette.secondary : Palette.text)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(selected ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func choose(_ service: TranscriptionService) {
        app.settings.settings.transcriptionService = service
        app.setup.recheck()
        picker = nil
    }

    private func choose(_ service: SummaryService) {
        app.settings.settings.summaryService = service
        app.setup.recheck()
        picker = nil
    }

    private func fetchModels() async {
        listingFailed = false
        loadingModels = false
        guard let endpoint = settings.openAIBaseURL else { return }
        loadingModels = true
        do {
            let key = try app.setup.field(.openAICompatibleAPIKey).savedSecret()
            let models = try await OpenAICompatibleLLM(baseURL: endpoint, apiKey: key, model: "").availableModels()
            guard !Task.isCancelled else { return }
            modelCache = ModelList(endpoint: endpoint, models: models)
        } catch {
            guard !Task.isCancelled else { return }
            listingFailed = true
        }
        loadingModels = false
    }

    private func configured(_ service: ModelService) -> Bool {
        app.setup.isConfigured(service, signedIn: app.collabAccount?.user != nil)
    }

    private func serviceRow(_ service: ModelService) -> some View {
        Button { editor = service } label: {
            HStack(spacing: 10) {
                tile(service.icon, highlighted: service == .mm2t)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: service.title).font(Typo.bodyStrong)
                    if let subtitle = subtitle(service) {
                        Text(verbatim: subtitle).font(Typo.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if configured(service) {
                    Circle().fill(Palette.success).frame(width: 7, height: 7)
                        .accessibilityLabel("Configured")
                } else {
                    Text(service.setupAction).font(Typo.caption).foregroundStyle(Palette.secondary)
                    Icon("chevron-right", size: 14).foregroundStyle(Palette.secondary)
                }
            }
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
    }

    private func subtitle(_ service: ModelService) -> String? {
        switch service {
        case .mm2t:
            guard app.collabAccount?.user != nil else { return nil }
            guard let quota = app.collabAccount?.quota else { return planName }
            return String(localized: "\(planName) · \(quota.used) / \(quota.limit) shared meetings")
        case .elevenLabs: return String(localized: "Transcription")
        case .gemini: return String(localized: "Summaries")
        case .openAICompatible:
            guard let host = settings.openAIBaseURL?.host() else { return nil }
            guard let count = cachedModels?.count else { return host }
            return String(localized: "\(host) · \(count) models")
        case .transcriptionServer: return settings.selfHostedURL?.host()
        }
    }

    private func tile(_ icon: String, highlighted: Bool = false) -> some View {
        Icon(icon, size: 15)
            .foregroundStyle(highlighted ? Palette.orange : Palette.secondary)
            .frame(width: 26, height: 26)
            .background(highlighted ? Palette.orangeSoft : Palette.tonal, in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}
