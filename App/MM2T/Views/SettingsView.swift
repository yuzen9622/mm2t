import AppKit
import MM2TApp
import MM2TCore
import MM2TLocal
import MM2TProviders
import MM2TSystem
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
    case account
    case models
    case general
    case assistant
    case privacy
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .assistant: String(localized: "Assistant")
        case .privacy: String(localized: "Privacy")
        case .account: String(localized: "Account")
        case .models: String(localized: "Models and services")
        case .about: String(localized: "About")
        }
    }

    var icon: String {
        switch self {
        case .general, .assistant: "adjustments-horizontal"
        case .privacy: "shield-check"
        case .account: "user-circle"
        case .models: "sparkles"
        case .about: "info-circle"
        }
    }
}

/// One setting the search can find. A new setting is a case here, a place in its group's `rows`,
/// and its view in `SettingsRowView`.
enum SettingsRow: Hashable {
    case transcriptionLanguage, liveCaptions, modelsServices
    case diarizationModel, translationEnabled, translationModel
    case appLanguage, assistantMemory
    case hideFromCapture
    case recordShortcut
    case promptApps, promptSites
    case systemPermissions, calendars, reminders, account
    case version, sourceCode, author, buyMeACoffee
    case privacyPolicy, terms, licenses

    /// The words the row shows, which a search matches along with its group's and section's names.
    var terms: [String] {
        switch self {
        case .transcriptionLanguage: [String(localized: "Meeting language"), String(localized: "Auto-detect"), "中文", "English"]
        case .modelsServices:
            [String(localized: "Post-meeting transcription"), String(localized: "Summaries and assistant"),
             String(localized: "Models"), String(localized: "Services"), String(localized: "Server URL"),
             String(localized: "Summary"),
             String(localized: "API key"), String(localized: "Token"), "OpenAI", "Scribe"]
                + ModelService.allCases.map(\.title)
        case .liveCaptions: [String(localized: "Live captions"), String(localized: "Live caption model")]
        case .translationEnabled: [String(localized: "Enable translation")]
        case .translationModel: [String(localized: "Translate captions"), String(localized: "Translation model"),
                                 "Apple Translation", "Mozilla Firefox Translations", "Bergamot", "Tencent Hy-MT2"] + CaptionTarget.all.map(\.name)
        case .diarizationModel: [String(localized: "Speaker separation model (about 230 MB) runs on this Mac.")]
        case .assistantMemory: [String(localized: "Personalized memory"), String(localized: "Conversation history"), String(localized: "Preference")]
        case .appLanguage: [String(localized: "App language"), "English", "繁體中文"]
        case .hideFromCapture: [String(localized: "Hide mm2t from screen sharing and screenshots")]
        case .recordShortcut: [String(localized: "Start or stop recording")]
        case .promptApps: [String(localized: "Apps")] + DetectionPolicy.callApps.map(\.name)
        case .promptSites: [String(localized: "Websites")] + MeetingPlatform.allCases.map(\.displayName)
        case .systemPermissions: [String(localized: "Microphone"), String(localized: "System audio recording"),
                                  String(localized: "Accessibility"), String(localized: "Automation")]
        case .calendars: ["Apple", "Google", "Outlook"]
        case .account: [String(localized: "Account"), String(localized: "Sign in with Google"), String(localized: "Sign in with Apple"), String(localized: "Sign Out")]
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
            SettingsGroup(id: "models", section: .models, title: SettingsSection.models.title, rows: [.modelsServices]),
            SettingsGroup(id: "assistant", section: .assistant, title: String(localized: "Personalized memory"), rows: [.assistantMemory]),
            SettingsGroup(id: "transcription", section: .general, title: String(localized: "Transcription"),
                          rows: [.transcriptionLanguage, .liveCaptions]),
            SettingsGroup(id: "translation", section: .general, title: String(localized: "Translation"), rows: [.translationEnabled, .translationModel]),
            SettingsGroup(id: "diarization", section: .general, title: String(localized: "Speaker separation"),
                          rows: [.diarizationModel]),
            SettingsGroup(id: "shortcut", section: .general, title: String(localized: "Keyboard shortcut"), rows: [.recordShortcut]),
            SettingsGroup(id: "language", section: .general, title: String(localized: "Language"), rows: [.appLanguage]),
            SettingsGroup(id: "privacy", section: .privacy, title: String(localized: "Privacy"), rows: [.hideFromCapture]),
            SettingsGroup(id: "prompts", section: .general, title: String(localized: "Recording prompts"),
                          rows: [.promptApps, .promptSites]),
            SettingsGroup(id: "system", section: .privacy, title: String(localized: "macOS permissions"), rows: [.systemPermissions]),
            SettingsGroup(id: "calendars", section: .privacy, title: String(localized: "Calendars"), rows: [.calendars]),
            SettingsGroup(id: "reminders", section: .privacy, title: String(localized: "Reminders"), rows: [.reminders]),
            SettingsGroup(id: "account", section: .account, title: SettingsSection.account.title, rows: [.account]),
            SettingsGroup(id: "app", section: .about, title: "mm2t", rows: [.version, .sourceCode, .author, .buyMeACoffee]),
            SettingsGroup(id: "legal", section: .about, title: String(localized: "Legal"), rows: [.privacyPolicy, .terms, .licenses]),
        ]
    }

    /// The groups `section` shows, or, while searching, every group's matching rows across sections.
    static func visible(in section: SettingsSection, query: String, accountAvailable: Bool) -> [SettingsGroup] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let available = all.filter { accountAvailable || $0.section != .account }
        guard !query.isEmpty else { return available.filter { $0.section == section } }
        return available.compactMap { group in
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

    private var navigation: MainNavigation { MainNavigation.shared }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            sectionList
            Group {
                if showLicenses {
                    // The notices open in place of the page, not in a window of their own.
                    VStack(alignment: .leading, spacing: 0) {
                        IconButton("Back", icon: "chevron-left") { showLicenses = false }
                            .padding(.leading, 16)
                            .padding(.top, 14)
                        AboutView()
                    }
                    .transition(.opacity)
                } else {
                    FadingScrollView {
                        SettingsPage(app: app, section: navigation.settingsSection, query: query, showLicenses: $showLicenses)
                            .padding(.horizontal, 28)
                            .padding(.top, 22)
                            .padding(.bottom, 28)
                    }
                    // Each section, and each search, starts at its top.
                    .id("\(navigation.settingsSection)-\(searching)")
                    .defaultScrollAnchor(.top)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .motion(Motion.reveal, value: showLicenses)
            .overlay(alignment: .topTrailing) {
                IconButton("Close", icon: "x") { navigation.settingsOpen = false }
                    // While a list is open, Esc closes the list instead.
                    .keyboardShortcut(DropdownState.shared.open == nil ? .cancelAction : nil)
                    .padding(14)
            }
        }
        .foregroundStyle(Palette.text)
        .font(Typo.body)
        .background(Palette.window)
        .tipLayer()
        .onAppear { app.setup.recheck() }
        .onChange(of: app.settings.settings) { app.setup.recheck() }
        .onChange(of: searching) { if searching { showLicenses = false } }
    }

    private var sectionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings").font(Typo.heading).padding(.horizontal, 6).padding(.top, 8)
            SearchField(text: $query).padding(.top, 14).padding(.bottom, 16)
            ForEach(SettingsSection.allCases.filter { app.collabAccount != nil || $0 != .account }) { section in
                SettingsSectionRow(section: section, isSelected: !searching && !showLicenses && navigation.settingsSection == section) {
                    query = ""
                    showLicenses = false
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
        let groups = SettingsGroup.visible(in: section, query: query, accountAvailable: app.collabAccount != nil)
        VStack(alignment: .leading, spacing: 24) {
            if !searching {
                Text(section.title).font(Typo.title)
            } else if groups.isEmpty {
                Text("No settings match “\(query)”.")
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 60)
            }
            ForEach(groups) { group in
                if group.section == .models {
                    VStack(alignment: .leading, spacing: 10) {
                        if searching { Text(group.title).font(Typo.captionStrong).foregroundStyle(Palette.secondary) }
                        ModelsServicesPage(app: app)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        if group.title != group.section.title || searching {
                            Text(searching && group.title != group.section.title ? "\(group.section.title) › \(group.title)" : group.title)
                                .font(Typo.captionStrong).foregroundStyle(Palette.secondary).padding(.leading, 4)
                        }
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(group.rows, id: \.self) { row in
                                SettingsRowView(app: app, row: row, showLicenses: $showLicenses)
                            }
                        }
                        .card()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .toggleStyle(SwitchStyle())
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
        case .account:
            if let account = app.collabAccount { CollabAccountSettings(account: account) }
        case .assistantMemory:
            AssistantMemorySettings(preferences: app.assistantPreferences, conversations: app.assistantConversations)
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
        case .modelsServices: EmptyView()
        case .translationEnabled: TranslationEnableRow(app: app)
        case .translationModel: CaptionTranslationRow(app: app)
        case .liveCaptions:
            LiveCaptionsRow(app: app)
        case .diarizationModel:
            ModelDownloadView(setup: app.setup)
        case .appLanguage:
            LanguagePicker()
        case .hideFromCapture:
            Toggle("Hide mm2t from screen sharing and screenshots", isOn: $store.settings.hidesFromScreenCapture)
        case .recordShortcut:
            RecordShortcutRow(app: app)
        case .promptApps:
            PromptAppRules(store: store)
        case .promptSites:
            PromptSiteRules(store: store)
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
                Text("Third-party notices")
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

/// The self-hosted server's address, saved as the user types so the token check beside it always sees it.
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

/// The app's own UI language. It switches at once; the next launch also starts in it.
private struct LanguagePicker: View {
    private static let domain = Bundle.main.bundleIdentifier ?? "dev.mm2t.app"
    @State private var choice = AppLanguage.current(in: .standard, domain: domain)

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
        .onChange(of: choice) { _, language in LiveLanguage.shared.apply(language) }
    }
}

private struct LiveCaptionsRow: View {
    let app: AppController

    var body: some View {
        @Bindable var store = app.settings
        Toggle("Live captions", isOn: $store.settings.liveCaptions)
        SpeechModelPicker(store: store, setup: app.setup)
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
                Text("Downloading speaker separation model (about 230 MB)")
                ProgressLine(fraction: fraction)
            }
        case .notDownloaded, .failed:
            HStack {
                Text("Speaker separation model (about 230 MB) runs on this Mac.")
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
struct SpeechModelPicker: View {
    @Bindable var store: SettingsStore
    let setup: SetupModel

    private let label: LocalizedStringKey = "Live caption model"

    var body: some View {
        picker
        if let model = store.settings.effectiveCaptionModel {
            OfflineModelView(model: OfflineModel(model), setup: setup)
        }
    }

    private var picker: some View {
        let selection = Binding<LocalSpeechModel?>(
            get: { store.settings.effectiveCaptionModel },
            set: { choice in
                if let choice { setup.selectSpeechModel(choice, for: \.localCaptionModel) }
            }
        )
        let options = setup.speechModelChoices.map { choice in
            let model = OfflineModel(choice)
            let mb = Int((Double(setup.offlineModelBytes(model)) / 1_000_000).rounded())
            return DropdownOption(id: Optional(choice), title: choice.name, detail: setup.offlineModels[model] == .downloaded ? nil : "\(mb) MB")
        }
        return HStack {
            Text(label)
            Spacer()
            Dropdown(label: label, options: options, selection: selection, placeholder: String(localized: "Choose a model"))
                .onAppear {
                    if let choice = selection.wrappedValue, setup.offlineModels[OfflineModel(choice)] == .notDownloaded {
                        Task { await setup.downloadOfflineModel(OfflineModel(choice)) }
                    }
                }
        }
    }
}

struct OfflineModelView: View {
    let model: OfflineModel
    let setup: SetupModel

    var body: some View {
        if case .unsuited(let reason) = setup.fit(for: model) {
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
            if model == .breezeCoreML, setup.preparingCoreML {
                HStack { ProgressView().controlSize(.small); Text("Preparing Breeze Core ML…") }
            } else if model == .breezeCoreML, let error = setup.coreMLPreparationError {
                HStack {
                    Text(error)
                    PillButton("Retry", icon: "refresh") { Task { await setup.prepareInstalledCoreML() } }
                }
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 8) {
                Text("Downloading \(size)")
                ProgressLine(fraction: fraction)
            }
        case .notDownloaded:
            EmptyView()
        case .failed(let reason):
            HStack {
                Text(reason).font(Typo.caption).foregroundStyle(Palette.danger)
                PillButton("Retry", icon: "refresh") { Task { await setup.downloadOfflineModel(model) } }
            }
        }
    }

    private var size: String {
        ByteCountFormatter.string(fromByteCount: setup.offlineModelBytes(model), countStyle: .file)
    }
}

// MARK: Record shortcut

/// The global shortcut that starts and stops a recording, and what keeps it from working.
private struct RecordShortcutRow: View {
    let app: AppController
    @State private var listening = false

    var body: some View {
        @Bindable var store = app.settings
        Group {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start or stop recording")
                    if listening {
                        Text("Press the new shortcut. Esc cancels.")
                            .font(Typo.caption).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                ShortcutField(app: app, shortcut: $store.settings.recordShortcut, listening: $listening)
            }
            if app.setup.accessibility != .granted {
                HStack(spacing: 12) {
                    Text("Needs Accessibility permission. Until it is on, the shortcut does nothing.")
                        .font(Typo.caption).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    PillButton("Open System Settings") { SetupModel.openSettings(.accessibility) }
                }
            }
        }
        .motion(Motion.reveal, value: app.setup.accessibility)
        .task {
            // macOS sends no notification when the Accessibility switch is flipped.
            while !Task.isCancelled {
                app.setup.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// Shows the shortcut; clicked, it listens for a new one. While it listens the shortcut itself is
/// off, and the keys pressed go nowhere else.
private struct ShortcutField: View {
    let app: AppController
    @Binding var shortcut: Hotkey
    @Binding var listening: Bool
    @State private var recorder = HotkeyRecorder()
    @State private var monitor: Any?
    @State private var hovering = false

    /// kVK_Escape.
    private static let escape: UInt16 = 53

    var body: some View {
        Button { listening ? stop() : start() } label: {
            Group {
                if listening { Text("Press keys…") } else { Text(verbatim: shortcut.symbols) }
            }
            .font(Typo.captionStrong)
            .foregroundStyle(listening ? Palette.orange : Palette.text)
            .padding(.horizontal, 14)
            .frame(minWidth: 96)
            .frame(height: 30)
            .background(listening ? Palette.orangeSoft : hovering ? Palette.selected : Palette.tonal, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
        .motion(Motion.select, value: listening)
        .onDisappear(perform: stop)
        .accessibilityLabel("Start or stop recording")
        .accessibilityValue(Text(verbatim: shortcut.symbols))
    }

    private func start() {
        recorder = HotkeyRecorder()
        app.suspendsRecordShortcut = true
        listening = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            MainActor.assumeIsolated { listen(event) }
            // Key presses are swallowed so they neither type nor press a button behind the field.
            return event.type == .keyDown ? nil : event
        }
    }

    private func listen(_ event: NSEvent) {
        let modifiers = HotkeyModifiers(event.modifierFlags)
        if event.type == .keyDown, event.keyCode == Self.escape, modifiers.isEmpty { return stop() }
        let recorded = event.type == .flagsChanged
            ? recorder.modifiersChanged(modifiers)
            : recorder.keyDown(event.keyCode, modifiers: modifiers, label: Self.label(event))
        if let recorded {
            shortcut = recorded
            stop()
        }
    }

    private func stop() {
        monitor.map(NSEvent.removeMonitor)
        monitor = nil
        listening = false
        app.suspendsRecordShortcut = false
    }

    /// Keys that type nothing get the symbols macOS menus use; the rest read as their character.
    private static func label(_ event: NSEvent) -> String {
        let named: [UInt16: String] = [
            49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return named[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "?"
    }
}
