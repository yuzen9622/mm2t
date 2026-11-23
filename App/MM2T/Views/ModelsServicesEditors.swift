import MM2TApp
import MM2TProviders
import SwiftUI

struct ServiceEditor: View {
    let app: AppController
    let service: ModelService
    var onModelsChanged: (URL, [String]?) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch service {
            case .mm2t:
                if let account = app.collabAccount { CollabAccountSettings(account: account, showsPlan: true) }
                else { Text("mm2t plan sign-in is unavailable.").foregroundStyle(Palette.danger) }
            case .elevenLabs, .gemini:
                ServiceKeyEditor(field: app.setup.field(service == .elevenLabs ? .elevenLabsAPIKey : .geminiAPIKey), setup: app.setup)
            case .openAICompatible, .transcriptionServer:
                ServiceServerEditor(app: app, service: service, onModelsChanged: onModelsChanged)
            }
        }
    }
}

private struct ServiceKeyEditor: View {
    let field: CredentialField
    let setup: SetupModel
    @State private var text = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                FieldBox { SecureField("API key", text: $text).onSubmit { if canSave { save() } } }
                PillButton("Save", kind: .primary, action: save).disabled(!canSave)
                if field.hasSavedValue {
                    PillButton("Remove", kind: .danger) {
                        text = ""
                        field.text = ""
                        field.save()
                        setup.recheck()
                    }
                    .disabled(saving)
                }
            }
            if !Copy.keyState(field.state).isEmpty {
                Text(verbatim: Copy.keyState(field.state)).font(Typo.caption).foregroundStyle(Palette.secondary)
            }
        }
        .onAppear { field.load(); text = field.text }
    }

    private var canSave: Bool { !saving && !Secret(text).isEmpty }

    private func save() {
        saving = true
        field.text = text
        Task {
            await field.validate()
            setup.recheck()
            saving = false
        }
    }
}

private struct ServiceServerEditor: View {
    let app: AppController
    let service: ModelService
    let onModelsChanged: (URL, [String]?) -> Void
    @State private var address = ""
    @State private var key = ""
    @State private var model = ""
    @State private var listed: [String]?
    @State private var testing = false
    @State private var status: String?
    @State private var error: String?

    private var isLLM: Bool { service == .openAICompatible }
    private var field: CredentialField { app.setup.field(isLLM ? .openAICompatibleAPIKey : .selfHostedToken) }
    private var savedURL: URL? { isLLM ? app.settings.settings.openAIBaseURL : app.settings.settings.selfHostedURL }
    private var endpoint: URL? { isLLM ? AppSettings.openAIBaseURL(from: address) : AppSettings.selfHostedURL(from: address) }
    private var savedModel: String { app.settings.settings.openAIModel }
    private var hasChanges: Bool {
        endpoint != savedURL || Secret(key).revealed != field.text || (isLLM && model != savedModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldBox { TextField("Server URL", text: $address) }
            FieldBox { SecureField(isLLM ? "API key (optional)" : "Token (optional)", text: $key) }
            if isLLM {
                HStack {
                    FieldBox { TextField("Model name", text: $model) }
                    if let listed, !listed.isEmpty {
                        Menu("Available models") {
                            ForEach(listed, id: \.self) { name in Button(name) { model = name } }
                        }
                        .fixedSize()
                    }
                }
            }
            HStack(spacing: 8) {
                PillButton("Save", kind: .primary, action: save).disabled(testing || endpoint == nil || !hasChanges)
                PillButton("Test connection", icon: "plug-connected") { test() }.disabled(testing || endpoint == nil)
                if savedURL != nil || field.hasSavedValue {
                    PillButton("Remove", kind: .danger, action: remove).disabled(testing)
                }
            }
            if testing { ProgressView().controlSize(.small) }
            if !address.isEmpty, endpoint == nil {
                Text("Enter a full http:// or https:// address.").font(Typo.caption).foregroundStyle(Palette.danger)
            } else if let error {
                Text(verbatim: error).font(Typo.caption).foregroundStyle(Palette.danger)
            } else if let status {
                Text(verbatim: status).font(Typo.caption).foregroundStyle(Palette.success)
            }
        }
        .onAppear {
            field.load()
            address = savedURL?.absoluteString ?? ""
            key = field.text
            model = isLLM ? savedModel : ""
        }
        .onChange(of: address) { resetTest() }
        .onChange(of: key) { resetTest() }
    }

    private func resetTest() {
        status = nil
        error = nil
        listed = nil
    }

    private func save() {
        guard let endpoint else { return }
        error = nil
        let credentialChanged = Secret(key) != Secret(field.text)
        field.text = key
        field.save()
        if case .storageFailed = field.state {
            error = Copy.keyState(field.state)
            field.load()
            return
        }
        key = field.text
        var updated = app.settings.settings
        if isLLM {
            if updated.openAIBaseURL != endpoint || listed != nil || credentialChanged {
                onModelsChanged(endpoint, listed)
            }
            updated.openAIBaseURL = endpoint
            updated.openAIModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            updated.selfHostedURL = endpoint
        }
        app.settings.settings = updated
        app.setup.recheck()
    }

    private func remove() {
        error = nil
        field.text = ""
        field.save()
        if case .storageFailed = field.state {
            error = Copy.keyState(field.state)
            field.load()
            return
        }
        var updated = app.settings.settings
        if isLLM {
            if let savedURL { onModelsChanged(savedURL, nil) }
            updated.openAIBaseURL = nil
            updated.openAIModel = ""
        } else {
            updated.selfHostedURL = nil
        }
        app.settings.settings = updated
        app.setup.recheck()
        address = ""
        key = ""
        model = ""
        resetTest()
    }

    private func test() {
        guard let endpoint else { return }
        let secret = Secret(key)
        testing = true
        resetTest()
        Task {
            defer { testing = false }
            do {
                if isLLM {
                    let models = try await OpenAICompatibleLLM(baseURL: endpoint, apiKey: secret, model: "").availableModels()
                    guard self.endpoint == endpoint, Secret(key) == secret else { return }
                    listed = models
                    if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let first = models.first { model = first }
                    status = String(localized: "Connected · \(models.count) models")
                    if endpoint == savedURL, secret == Secret(field.text) { onModelsChanged(endpoint, models) }
                } else {
                    let check = await SelfHostedTranscription(baseURL: endpoint, token: secret).validateKey()
                    guard self.endpoint == endpoint, Secret(key) == secret else { return }
                    switch check {
                    case .valid: status = String(localized: "Connected")
                    case .rejected(let reason), .inconclusive(let reason): error = reason
                    }
                }
            } catch {
                guard self.endpoint == endpoint, Secret(key) == secret else { return }
                if error is OpenAICompatibleLLM.ModelListingError {
                    self.error = String(localized: "This server does not support model listing. Enter a model ID manually.")
                } else {
                    self.error = (error as? ProviderError)?.description ?? String(localized: "Couldn't reach the OpenAI-compatible server.")
                }
            }
        }
    }
}
