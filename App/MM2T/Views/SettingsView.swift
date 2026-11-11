import MM2TApp
import MM2TCore
import MM2TProviders
import SwiftUI

struct SettingsView: View {
    let app: AppController
    @State private var serverURL = ""
    @State private var showLicenses = false

    var body: some View {
        @Bindable var store = app.settings
        VStack(spacing: 0) {
            ScreenHeader(title: Text("Settings")) {
                PillButton("Licenses") { showLicenses = true }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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
                            CredentialFieldView(field: app.setup.field(.selfHostedToken))
                        }
                        Divider().overlay(Palette.border)
                        SourceToggle(source: .cloud, store: store)
                        if store.settings.transcriptionOrder.contains(.cloud) {
                            CredentialFieldView(field: app.setup.field(.elevenLabsAPIKey))
                        }
                        Divider().overlay(Palette.border)
                        Toggle(Copy.source(.local), isOn: .constant(false)).disabled(true)
                        Text("Sources are tried top to bottom. mm2t moves to the next one only when a source can't be reached.")
                            .font(Typo.caption).foregroundStyle(Palette.secondary)
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
                        CredentialFieldView(field: app.setup.field(.geminiAPIKey))
                        Text("Use a Gemini key from a paid plan. On the free tier, Google may use what you send to improve its products.")
                            .font(Typo.caption).foregroundStyle(Palette.secondary)
                        Divider().overlay(Palette.border)
                        Toggle("Generate on this Mac", isOn: .constant(false)).disabled(true)
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
                store.settings.transcriptionOrder = [TranscriptionSource.selfHosted, .cloud].filter(enabled.contains)
            }))
    }
}

struct CredentialFieldView: View {
    @Bindable var field: CredentialField

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Icon("key", size: 15).foregroundStyle(Palette.muted)
                FieldBox {
                    SecureField(Copy.credentialName(field.credential), text: $field.text)
                        .onSubmit { field.save() }
                }
                PillButton("Verify") { Task { await field.validate() } }
                    .disabled(field.text.isEmpty || field.state == .validating)
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
