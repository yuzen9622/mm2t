import AppKit
import MM2TApp
import MM2TCore
import MM2TLocal
import MM2TProviders
import SwiftUI

/// Addresses the app points people to. Change them here.
enum AppLinks {
    static let repository = URL(string: "https://github.com/yuzen9622/mm2t")!
    static let help = URL(string: "https://github.com/yuzen9622/mm2t#readme")!
    static let privacyPolicy = URL(string: "https://github.com/yuzen9622/mm2t/blob/main/PRIVACY.md")!
    static let terms = URL(string: "https://github.com/yuzen9622/mm2t/blob/main/TERMS.md")!
    static let authorName = "yuzen9622"
    static let author = URL(string: "https://github.com/yuzen9622")!
    /// Placeholder until the real page exists.
    static let buyMeACoffee = URL(string: "https://buymeacoffee.com/yuzen9622")!
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case permissions
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .permissions: String(localized: "Permissions")
        case .about: String(localized: "About")
        }
    }

    var icon: String {
        switch self {
        case .general: "adjustments-horizontal"
        case .permissions: "shield-check"
        case .about: "info-circle"
        }
    }
}

/// One setting the search can find. A new setting is a case here, a place in its group's `rows`,
/// and its view in `SettingsRowView`.
enum SettingsRow: Hashable {
    case transcriptionLanguage, selfHostedTranscription, cloudTranscription, localTranscription
    case diarizationOrder, diarizationModel
    case summaryBackend, geminiKey, localSummaries
    case appLanguage
    case hideFromCapture
    case systemPermissions, calendars, reminders
    case version, sourceCode, author, buyMeACoffee
    case privacyPolicy, terms, licenses

    /// The words the row shows, which a search matches along with its group's and section's names.
    var terms: [String] {
        switch self {
        case .transcriptionLanguage: [String(localized: "Meeting language"), String(localized: "Auto-detect"), "中文", "English"]
        case .selfHostedTranscription: [Copy.source(.selfHosted), String(localized: "Server URL"), Copy.credentialName(.selfHostedToken)]
        case .cloudTranscription: [Copy.source(.cloud), Copy.credentialName(.elevenLabsAPIKey)]
        case .localTranscription: [Copy.source(.local)]
        case .diarizationOrder: [String(localized: "Try first")] + DiarizationSource.allCases.map(Copy.diarization)
        case .diarizationModel: [String(localized: "Speaker separation model (about 210 MB) runs on this Mac.")]
        case .summaryBackend: [String(localized: "Summary model"), "Gemini", String(localized: "Self-hosted (OpenAI-compatible)"),
                               String(localized: "Model name"), Copy.credentialName(.openAICompatibleAPIKey)]
        case .geminiKey: [Copy.credentialName(.geminiAPIKey)]
        case .localSummaries: [String(localized: "Generate on this Mac")]
        case .appLanguage: [String(localized: "App language"), "English", "繁體中文"]
        case .hideFromCapture: [String(localized: "Hide mm2t from screen sharing and screenshots")]
        case .systemPermissions: [String(localized: "Microphone"), String(localized: "System audio recording"),
                                  String(localized: "Accessibility"), String(localized: "Automation")]
        case .calendars: ["Apple", "Google", "Outlook"]
        case .reminders: [String(localized: "Reminders"), String(localized: "To-dos")]
        case .version: [String(localized: "Version")]
        case .sourceCode: [String(localized: "Source code"), "GitHub"]
        case .author: [String(localized: "Made by \(AppLinks.authorName)")]
        case .buyMeACoffee: [String(localized: "Buy Me a Coffee")]
        case .privacyPolicy: [String(localized: "Privacy Policy")]
        case .terms: [String(localized: "Terms of Service")]
        case .licenses: [String(localized: "Third-party notices"), String(localized: "Licenses")]
        }
    }
}

/// A titled card of rows in one section, in the order the dialog shows them.
struct SettingsGroup: Identifiable {
    let id: String
    let section: SettingsSection
    let title: String
    let rows: [SettingsRow]

    static var all: [SettingsGroup] {
        [
            SettingsGroup(id: "transcription", section: .general, title: String(localized: "Transcription"),
                          rows: [.transcriptionLanguage, .selfHostedTranscription, .cloudTranscription, .localTranscription]),
            SettingsGroup(id: "diarization", section: .general, title: String(localized: "Speaker separation"),
                          rows: [.diarizationOrder, .diarizationModel]),
            SettingsGroup(id: "summaries", section: .general, title: String(localized: "Summaries"),
                          rows: [.summaryBackend, .geminiKey, .localSummaries]),
            SettingsGroup(id: "language", section: .general, title: String(localized: "Language"), rows: [.appLanguage]),
            SettingsGroup(id: "privacy", section: .general, title: String(localized: "Privacy"), rows: [.hideFromCapture]),
            SettingsGroup(id: "system", section: .permissions, title: String(localized: "macOS permissions"), rows: [.systemPermissions]),
            SettingsGroup(id: "calendars", section: .permissions, title: String(localized: "Calendars"), rows: [.calendars]),
            SettingsGroup(id: "reminders", section: .permissions, title: String(localized: "Reminders"), rows: [.reminders]),
            SettingsGroup(id: "app", section: .about, title: "mm2t", rows: [.version, .sourceCode, .author, .buyMeACoffee]),
            SettingsGroup(id: "legal", section: .about, title: String(localized: "Legal"), rows: [.privacyPolicy, .terms, .licenses]),
        ]
    }

    /// The groups `section` shows, or, while searching, every group's matching rows across sections.
    static func visible(in section: SettingsSection, query: String) -> [SettingsGroup] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all.filter { $0.section == section } }
        return all.compactMap { group in
            if group.title.localizedStandardContains(query) || group.section.title.localizedStandardContains(query) { return group }
            let rows = group.rows.filter { $0.terms.contains { $0.localizedStandardContains(query) } }
            return rows.isEmpty ? nil : SettingsGroup(id: group.id, section: group.section, title: group.title, rows: rows)
        }
    }
}

/// Settings, as a dialog over the main window: a search across every row, the sections on the left.
struct SettingsDialog: View {
    let app: AppController
    @State private var query = ""
    @State private var showLicenses = false
    @Environment(\.dismiss) private var dismiss

    private var navigation: MainNavigation { MainNavigation.shared }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            sectionList
            ScrollView {
                SettingsPage(app: app, section: navigation.settingsSection, query: query, showLicenses: $showLicenses)
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                    .padding(.bottom, 28)
            }
            // Each section, and each search, starts at its top.
            .id("\(navigation.settingsSection)-\(searching)")
            .defaultScrollAnchor(.top)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) {
                IconButton("Close", icon: "x") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .padding(14)
            }
        }
        .foregroundStyle(Palette.text)
        .font(Typo.body)
        .background(Palette.window)
        .frame(width: 780, height: 580)
        .tipLayer()
        .windowSharingNone()
        .sheet(isPresented: $showLicenses) {
            VStack(spacing: 0) {
                AboutView()
                HStack {
                    Spacer()
                    PillButton("Done", kind: .primary) { showLicenses = false }
                }
                .padding(16)
            }
            .frame(width: 560, height: 480)
            .background(Palette.window)
            .foregroundStyle(Palette.text)
        }
        .onAppear { app.setup.recheck() }
        .onChange(of: app.settings.settings) { app.setup.recheck() }
        .onChange(of: SnapshotStage.shared.settingsQuery, initial: true) { _, staged in
            if let staged { query = staged }
        }
    }

    private var sectionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings").font(Typo.heading).padding(.horizontal, 6).padding(.top, 8)
            SearchField(text: $query).padding(.top, 14).padding(.bottom, 16)
            ForEach(SettingsSection.allCases) { section in
                SettingsSectionRow(section: section, isSelected: !searching && navigation.settingsSection == section) {
                    query = ""
                    navigation.settingsSection = section
                }
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 208)
        .frame(maxHeight: .infinity)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Palette.shadow.opacity(0.5), radius: 8, y: 2)
        .padding(10)
    }
}

private struct SettingsSectionRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Icon(section.icon, size: 16).foregroundStyle(isSelected ? Palette.orange : Palette.secondary)
                Text(section.title)
                    .font(isSelected ? Typo.bodyStrong : Typo.body)
                    .foregroundStyle(isSelected ? Palette.text : Palette.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(isSelected ? Palette.selected : hovering ? Palette.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
        .motion(Motion.select, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One section's groups, or the search's matches from every section.
struct SettingsPage: View {
    let app: AppController
    let section: SettingsSection
    let query: String
    @Binding var showLicenses: Bool

    var body: some View {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let groups = SettingsGroup.visible(in: section, query: query)
        VStack(alignment: .leading, spacing: 24) {
            if !searching {
                Text(section.title).font(Typo.title)
                if section == .general, !app.setup.issues.isEmpty {
                    Panel(title: "Still needed") {
                        ForEach(app.setup.issues, id: \.self) { IssueRow(issue: $0) }
                    }
                    .entrance()
                }
            } else if groups.isEmpty {
                Text("No settings match “\(query)”.")
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 60)
            }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(searching ? "\(group.section.title) › \(group.title)" : group.title)
                        .font(Typo.captionStrong).foregroundStyle(Palette.secondary).padding(.leading, 4)
                    // Rows are set apart by space, not lines.
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(group.rows, id: \.self) { row in
                            SettingsRowView(app: app, row: row, showLicenses: $showLicenses)
                        }
                    }
                    .card()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .toggleStyle(SwitchStyle())
        .motion(Motion.reveal, value: app.settings.settings.transcriptionOrder)
        .motion(Motion.reveal, value: app.settings.settings.llmLocation)
        .motion(Motion.reveal, value: app.setup.issues)
    }
}

/// The controls of one settings row.
struct SettingsRowView: View {
    let app: AppController
    let row: SettingsRow
    @Binding var showLicenses: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { controls }
    }

    @ViewBuilder private var controls: some View {
        @Bindable var store = app.settings
        switch row {
        case .transcriptionLanguage:
            HStack {
                Text("Meeting language")
                Spacer()
                Segmented(options: TranscriptionLanguage.allCases, selection: $store.settings.transcriptionLanguage) { language in
                    switch language {
                    case .auto: String(localized: "Auto-detect")
                    case .chinese: "中文"
                    case .english: "English"
                    }
                }
            }
        case .selfHostedTranscription:
            SourceToggle(source: .selfHosted, store: store)
            if store.settings.transcriptionOrder.contains(.selfHosted) {
                ServerURLField(store: store)
                CredentialFieldView(field: app.setup.field(.selfHostedToken), setup: app.setup)
            }
        case .cloudTranscription:
            SourceToggle(source: .cloud, store: store)
            if store.settings.transcriptionOrder.contains(.cloud) {
                CredentialFieldView(field: app.setup.field(.elevenLabsAPIKey), setup: app.setup)
            }
        case .localTranscription:
            SourceToggle(source: .local, store: store)
            if store.settings.transcriptionOrder.contains(.local) {
                OfflineModelView(model: .transcription, fit: app.setup.suitability.transcription, setup: app.setup)
            }
        case .diarizationOrder:
            HStack {
                Text("Try first")
                Spacer()
                Segmented(options: DiarizationSource.allCases, selection: Binding(
                    get: { store.settings.diarizationOrder.first ?? .local },
                    set: { first in store.settings.diarizationOrder = [first] + DiarizationSource.allCases.filter { $0 != first } })) {
                    Copy.diarization($0)
                }
            }
        case .diarizationModel:
            ModelDownloadView(setup: app.setup)
        case .summaryBackend:
            if store.settings.llmLocation == .cloud {
                HStack {
                    Text("Summary model")
                    Spacer()
                    Segmented(options: CloudLLM.allCases, selection: $store.settings.cloudLLM) { backend in
                        switch backend {
                        case .gemini: "Gemini"
                        case .openAICompatible: String(localized: "Self-hosted (OpenAI-compatible)")
                        }
                    }
                }
                if store.settings.cloudLLM == .openAICompatible {
                    LLMServerFields(store: store)
                    CredentialFieldView(field: app.setup.field(.openAICompatibleAPIKey), setup: app.setup)
                }
            }
        case .geminiKey:
            if store.settings.llmLocation == .local || store.settings.cloudLLM == .gemini {
                CredentialFieldView(field: app.setup.field(.geminiAPIKey), setup: app.setup)
            }
        case .localSummaries:
            Toggle("Generate on this Mac", isOn: Binding(
                get: { store.settings.llmLocation == .local },
                set: { store.settings.llmLocation = $0 ? .local : .cloud }))
            if store.settings.llmLocation == .local {
                OfflineModelView(model: .llm, fit: app.setup.suitability.llm, setup: app.setup)
            }
        case .appLanguage:
            LanguagePicker()
        case .hideFromCapture:
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Hide mm2t from screen sharing and screenshots", isOn: $store.settings.hidesFromScreenCapture)
                Text("While on, screen shares, recordings and screenshots leave mm2t's windows out.")
                    .font(Typo.caption).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .systemPermissions:
            PermissionRows(setup: app.setup)
        case .calendars:
            CalendarSourceList(model: app.dashboard)
                .task { await app.dashboard.reloadCalendar() }
        case .reminders:
            RemindersRow(sync: app.reminders)
        case .version:
            HStack {
                Text("Version")
                Spacer()
                Text(verbatim: Self.version).foregroundStyle(Palette.secondary).textSelection(.enabled)
            }
        case .sourceCode:
            LinkRow(icon: "brand-github", title: "Source code", detail: "github.com/yuzen9622/mm2t", url: AppLinks.repository)
        case .author:
            LinkRow(icon: "user", title: "Made by \(AppLinks.authorName)", url: AppLinks.author)
        case .buyMeACoffee:
            LinkRow(icon: "coffee", title: "Buy Me a Coffee", url: AppLinks.buyMeACoffee)
        case .privacyPolicy:
            LinkRow(icon: "file-text", title: "Privacy Policy", url: AppLinks.privacyPolicy)
        case .terms:
            LinkRow(icon: "file-text", title: "Terms of Service", url: AppLinks.terms)
        case .licenses:
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Third-party notices")
                    Text("Licensed under AGPL-3.0.").font(Typo.caption).foregroundStyle(Palette.secondary)
                }
                Spacer()
                PillButton("Licenses") { showLicenses = true }
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }
}

/// A row that opens a web page.
private struct LinkRow: View {
    let icon: String
    let title: LocalizedStringKey
    var detail: String?
    let url: URL
    @State private var hovering = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(url) } label: {
            HStack(spacing: 10) {
                Icon(icon, size: 16).foregroundStyle(Palette.secondary)
                Text(title)
                Spacer(minLength: 8)
                if let detail { Text(verbatim: detail).font(Typo.caption).foregroundStyle(Palette.secondary) }
                Icon("external-link", size: 14).foregroundStyle(hovering ? Palette.orange : Palette.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
    }
}

/// The self-hosted server's address, saved when the user presses Return or leaves the row.
private struct ServerURLField: View {
    let store: SettingsStore
    @State private var text = ""

    var body: some View {
        FieldBox {
            TextField("Server URL", text: $text, prompt: Text(verbatim: "http://gpu.tailnet:8000"))
                .onSubmit(save)
        }
        .onAppear { text = store.settings.selfHostedURL?.absoluteString ?? "" }
        .onDisappear(perform: save)
        if !text.isEmpty, AppSettings.selfHostedURL(from: text) == nil {
            Text("Enter a full http:// or https:// address.").font(Typo.caption).foregroundStyle(Palette.danger)
        }
    }

    private func save() {
        store.settings.selfHostedURL = AppSettings.selfHostedURL(from: text)
    }
}

/// Where an OpenAI-compatible server (vLLM, Ollama, LM Studio, llama.cpp) answers, and which model to ask.
private struct LLMServerFields: View {
    let store: SettingsStore
    @State private var url = ""

    var body: some View {
        FieldBox {
            TextField("Server URL", text: $url, prompt: Text(verbatim: "http://localhost:11434/v1"))
                .onSubmit(save)
        }
        .onAppear { url = store.settings.openAIBaseURL?.absoluteString ?? "" }
        .onDisappear(perform: save)
        if !url.isEmpty, AppSettings.openAIBaseURL(from: url) == nil {
            Text("Enter a full http:// or https:// address.").font(Typo.caption).foregroundStyle(Palette.danger)
        }
        FieldBox {
            TextField("Model name", text: Binding(get: { store.settings.openAIModel }, set: { store.settings.openAIModel = $0 }),
                      prompt: Text(verbatim: "qwen2.5:14b"))
        }
    }

    private func save() {
        store.settings.openAIBaseURL = AppSettings.openAIBaseURL(from: url)
    }
}

/// Connects meeting to-dos to Apple Reminders, mirroring the Apple Calendar row.
private struct RemindersRow: View {
    let sync: RemindersSync

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reminders").font(Typo.bodyStrong)
                if sync.access == .granted {
                    Text("Connected. To-dos go to the “mm2t” list.").font(Typo.caption).foregroundStyle(Palette.secondary)
                }
            }
            Spacer()
            switch sync.access {
            case .granted:
                Icon("circle-check", size: 18).foregroundStyle(Palette.success)
            case .notDetermined:
                PillButton("Allow…", kind: .primary) { Task { await sync.requestAccess() } }
            default:
                PillButton("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
                }
            }
        }
    }
}

/// The app's own UI language. macOS reads it at launch, so a change offers a restart.
private struct LanguagePicker: View {
    private static let domain = Bundle.main.bundleIdentifier ?? "dev.mm2t.app"
    /// What this run of the app shows, read before any change in it.
    private static let atLaunch = AppLanguage.current(in: .standard, domain: domain)
    @State private var choice = Self.atLaunch

    var body: some View {
        HStack {
            Text("App language")
            Spacer()
            Segmented(options: AppLanguage.allCases, selection: $choice) { language in
                switch language {
                case .system: String(localized: "System")
                case .english: "English"
                case .traditionalChinese: "繁體中文"
                }
            }
        }
        .onAppear { choice = AppLanguage.current(in: .standard, domain: Self.domain) }
        .onChange(of: choice) { _, language in language.save(in: .standard) }
        if choice != Self.atLaunch {
            HStack(spacing: 8) {
                Icon("refresh", size: 15).foregroundStyle(Palette.orange)
                Text("Restart mm2t to use the new language.").fixedSize(horizontal: false, vertical: true)
                Spacer()
                PillButton("Restart", kind: .primary, action: Self.relaunch)
            }
            .transition(.opacity)
        }
    }

    /// Opens a new copy of the app once this one has quit.
    private static func relaunch() {
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                           Bundle.main.bundleURL.path, String(ProcessInfo.processInfo.processIdentifier)]
        try? shell.run()
        NSApp.terminate(nil)
    }
}

struct IssueRow: View {
    let issue: SetupIssue

    var body: some View {
        HStack(spacing: 8) {
            Icon("alert-triangle", size: 15).foregroundStyle(Palette.orange)
            Text(Copy.issue(issue))
        }
    }
}

/// On means the source is in the chain; self-hosted always goes before cloud.
struct SourceToggle: View {
    let source: TranscriptionSource
    let store: SettingsStore

    var body: some View {
        Toggle(Copy.source(source), isOn: Binding(
            get: { store.settings.transcriptionOrder.contains(source) },
            set: { on in
                let enabled = Set(store.settings.transcriptionOrder).union(on ? [source] : []).subtracting(on ? [] : [source])
                store.settings.transcriptionOrder = TranscriptionSource.allCases.filter(enabled.contains)
            }))
    }
}

struct CredentialFieldView: View {
    @Bindable var field: CredentialField
    let setup: SetupModel
    /// Typing after a successful check brings the Save button back.
    @State private var edited = false

    /// A key that passed its check and has not been changed since shows a check mark where Save was.
    private var verified: Bool {
        (field.state == .checked(.valid) && !edited) || SnapshotStage.shared.keysVerified
    }

    /// Saving and checking are one step: a key that was stored is a key that was tried.
    private func save() {
        edited = false
        Task {
            await field.validate()
            setup.recheck()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Icon("key", size: 15).foregroundStyle(Palette.muted)
                FieldBox {
                    SecureField(Copy.credentialName(field.credential), text: $field.text)
                        .onSubmit(save)
                }
                if verified {
                    Icon("circle-check", size: 18).foregroundStyle(Palette.success)
                        .frame(height: 30)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityElement()
                        .accessibilityLabel(Copy.keyState(.checked(.valid)))
                } else {
                    PillButton("Save", action: save)
                        .disabled(field.state == .validating)
                        .transition(.opacity)
                }
            }
            if field.state != .checked(.valid), !Copy.keyState(field.state).isEmpty {
                Text(Copy.keyState(field.state)).font(Typo.caption).foregroundStyle(Palette.secondary)
                    .padding(.leading, 23)
                    .transition(.opacity)
            }
        }
        .onChange(of: field.text) { if field.state == .checked(.valid) { edited = true } }
        .motion(Motion.reveal, value: field.state)
        .motion(Motion.reveal, value: verified)
    }
}

struct ModelDownloadView: View {
    let setup: SetupModel

    var body: some View {
        switch setup.models {
        case .downloaded:
            HStack(spacing: 8) {
                Icon("circle-check", size: 16).foregroundStyle(Palette.success)
                Text("Speaker separation model installed")
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 8) {
                Text("Downloading speaker separation model (about 210 MB)")
                ProgressLine(fraction: fraction)
            }
        case .notDownloaded, .failed:
            HStack {
                Text("Speaker separation model (about 210 MB) runs on this Mac.")
                Spacer()
                PillButton("Download", icon: "download") { Task { await setup.downloadModels() } }
            }
            if case .failed(let reason) = setup.models {
                Text(reason).font(Typo.caption).foregroundStyle(Palette.danger)
            }
        }
    }
}

/// One on-device model: whether this Mac suits it, and its download.
struct OfflineModelView: View {
    let model: OfflineModel
    let fit: OfflineFit
    let setup: SetupModel

    var body: some View {
        if case .unsuited(let reason) = fit {
            HStack(spacing: 8) {
                Icon("alert-triangle", size: 15).foregroundStyle(Palette.orange)
                switch reason {
                case .intelProcessor: Text("Not recommended on a Mac with an Intel processor.")
                case .memory(let minimumGB): Text("Not recommended: needs at least \(minimumGB) GB of memory.")
                }
            }
        }
        switch setup.offlineModels[model] ?? .notDownloaded {
        case .downloaded:
            HStack(spacing: 8) {
                Icon("circle-check", size: 16).foregroundStyle(Palette.success)
                Text("Model installed")
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 8) {
                Text("Downloading \(size)")
                ProgressLine(fraction: fraction)
            }
        case .notDownloaded, .failed:
            HStack {
                Text("Needs a model on this Mac (\(size)).")
                Spacer()
                PillButton("Download", icon: "download") { Task { await setup.downloadOfflineModel(model) } }
            }
            if case .failed(let reason) = setup.offlineModels[model] {
                Text(reason).font(Typo.caption).foregroundStyle(Palette.danger)
            }
        }
    }

    private var size: String {
        switch model {
        case .transcription: "1.1 GB"
        case .llm: "5.7 GB"
        }
    }
}
