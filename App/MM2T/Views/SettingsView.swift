import MM2TApp
import MM2TCore
import MM2TLocal
import MM2TProviders
import SwiftUI

struct SettingsView: View {
    let app: AppController
    @State private var serverURL = ""
    @State private var showLicenses = false

    var body: some View {
        @Bindable var store = app.settings
        VStack(spacing: 0) {
            ScreenHeader {
                PillButton("Licenses") { showLicenses = true }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Panel(title: "Permissions") {
                        PermissionRows(setup: app.setup)
                    }
                    Panel(title: "Calendars") {
                        CalendarSourceList(model: app.dashboard)
                            .task { await app.dashboard.reloadCalendar() }
                    }
                    Panel(title: "Transcription") {
                        SourceToggle(source: .selfHosted, store: store)
                        if store.settings.transcriptionOrder.contains(.selfHosted) {
                            FieldBox {
                                TextField("Server URL", text: $serverURL, prompt: Text(verbatim: "http://gpu.tailnet:8000"))
                                    .onSubmit(saveURL)
                            }
                            if !serverURL.isEmpty, AppSettings.selfHostedURL(from: serverURL) == nil {
                                Text("Enter a full http:// or https:// address.").font(Typo.caption).foregroundStyle(Palette.danger)
                            }
                            CredentialFieldView(field: app.setup.field(.selfHostedToken), setup: app.setup)
                        }
                        Divider().overlay(Palette.border)
                        SourceToggle(source: .cloud, store: store)
                        if store.settings.transcriptionOrder.contains(.cloud) {
                            CredentialFieldView(field: app.setup.field(.elevenLabsAPIKey), setup: app.setup)
                        }
                        Divider().overlay(Palette.border)
                        SourceToggle(source: .local, store: store)
                        if store.settings.transcriptionOrder.contains(.local) {
                            OfflineModelView(model: .transcription, fit: app.setup.suitability.transcription, setup: app.setup)
                        }
                    }
                    Panel(title: "Speaker separation") {
                        HStack {
                            Text("Try first")
                            Spacer()
                            Segmented(options: DiarizationSource.allCases, selection: Binding(
                                get: { store.settings.diarizationOrder.first ?? .local },
                                set: { first in store.settings.diarizationOrder = [first] + DiarizationSource.allCases.filter { $0 != first } })) {
                                Copy.diarization($0)
                            }
                        }
                        ModelDownloadView(setup: app.setup)
                    }
                    Panel(title: "Summaries") {
                        CredentialFieldView(field: app.setup.field(.geminiAPIKey), setup: app.setup)
                        Divider().overlay(Palette.border)
                        Toggle("Generate on this Mac", isOn: Binding(
                            get: { store.settings.llmLocation == .local },
                            set: { store.settings.llmLocation = $0 ? .local : .cloud }))
                        if store.settings.llmLocation == .local {
                            OfflineModelView(model: .llm, fit: app.setup.suitability.llm, setup: app.setup)
                        }
                    }
                    if !app.setup.issues.isEmpty {
                        Panel(title: "Still needed") {
                            ForEach(app.setup.issues, id: \.self) { IssueRow(issue: $0) }
                        }
                        .entrance()
                    }
                }
                .toggleStyle(SwitchStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .motion(Motion.reveal, value: store.settings.transcriptionOrder)
                .motion(Motion.reveal, value: store.settings.llmLocation)
                .motion(Motion.reveal, value: app.setup.issues)
            }
        }
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
        .onAppear {
            serverURL = store.settings.selfHostedURL?.absoluteString ?? ""
            app.setup.recheck()
        }
        .onChange(of: store.settings) { app.setup.recheck() }
        .onDisappear(perform: saveURL)
    }

    private func saveURL() {
        app.settings.settings.selfHostedURL = AppSettings.selfHostedURL(from: serverURL)
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

    /// Saving and checking are one step: a key that was stored is a key that was tried.
    private func save() {
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
                PillButton("Save", action: save)
                    .disabled(field.state == .validating)
            }
            if !Copy.keyState(field.state).isEmpty {
                Text(Copy.keyState(field.state)).font(Typo.caption).foregroundStyle(Palette.secondary)
                    .padding(.leading, 23)
                    .transition(.opacity)
            }
        }
        .motion(Motion.reveal, value: field.state)
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
