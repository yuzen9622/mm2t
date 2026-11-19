import AppKit
import MM2TApp
import MM2TCore
import MM2TLocal
import SwiftUI
import Translation

struct CaptionTranslationRow: View {
    let app: AppController
    @State private var appleLanguages: [AppleCaptionLanguage]?
    @State private var refresh = 0

    private struct CatalogRequest: Equatable {
        let engine: CaptionEngine
        let revision: Int
        let source: CaptionLanguage?
    }

    private var engine: CaptionEngine { app.settings.settings.captionEngine }
    private var choice: CaptionTranslation { app.settings.settings.captionTranslation }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Translation model")
                Spacer()
                Dropdown(label: "Translation model", options: engineOptions,
                         selection: Binding(get: { engine }, set: { new in Task { await app.setCaptionEngine(new) } }),
                         placeholder: String(localized: "Unavailable"))
            }
            if !AppleCaptionTranslator.isAvailable {
                Text("Apple Translation requires macOS 26 or later.")
                    .font(Typo.caption).foregroundStyle(Palette.secondary)
            }
            HStack {
                Text("Translate captions")
                Spacer()
                Dropdown(label: "Translate captions", options: targetOptions,
                         selection: Binding(get: { choice }, set: { new in Task { await app.setCaptionTranslation(new) } }),
                         placeholder: engine == .apple && appleLanguages == nil ? String(localized: "Checking…") : String(localized: "Unavailable"),
                         showsSelectedLeading: false)
                    .disabled(engine == .apple && (appleLanguages == nil || !AppleCaptionTranslator.isAvailable))
            }
            if engine == .apple {
                if let language = appleLanguages?.first(where: { $0.target == choice.target }),
                   !language.missingSources.isEmpty, #available(macOS 26, *) {
                    AppleModelDownload(language: language) { refresh += 1 }.id(language.target.id)
                } else if appleLanguages?.isEmpty == true, AppleCaptionTranslator.isAvailable {
                    Text("No system translation languages available.").font(Typo.caption).foregroundStyle(Palette.secondary)
                }
            } else if choice.target != nil {
                modelDownload
            }
        }
        .task(id: CatalogRequest(engine: engine, revision: refresh, source: app.settings.settings.transcriptionLanguage.fixedCaptionSource)) {
            if engine == .apple { await loadAppleLanguages() } else { appleLanguages = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if engine == .apple { refresh += 1 }
        }
    }

    private var engineOptions: [DropdownOption<CaptionEngine>] {
        CaptionEngine.allCases.compactMap { engine in
            switch engine {
            case .apple: AppleCaptionTranslator.isAvailable ? DropdownOption(id: engine, title: "Apple Translation") : nil
            case .firefox: DropdownOption(id: engine, title: "Mozilla Firefox Translations")
            case .hyMT2: DropdownOption(id: engine, title: "Tencent Hy-MT2")
            }
        }
    }

    private var targetOptions: [DropdownOption<CaptionTranslation>] {
        let off = DropdownOption(id: CaptionTranslation.off, title: String(localized: "Off"))
        if engine == .apple {
            return [off] + (appleLanguages ?? []).map { language in
                DropdownOption(id: CaptionTranslation(language.target), leading: language.target.flag.isEmpty ? nil : language.target.flag,
                               title: language.target.name,
                               trailing: language.missingSources.isEmpty ? String(localized: "Installed") : String(localized: "Needs download"))
            }
        }
        return [off] + (engine == .firefox ? CaptionTarget.all : CaptionTarget.hyTargets).map {
            DropdownOption(id: CaptionTranslation($0), leading: $0.flag.isEmpty ? nil : $0.flag, title: $0.name)
        }
    }

    private func loadAppleLanguages() async {
        let languages = await AppleCaptionTranslator.languages(source: app.settings.settings.transcriptionLanguage.fixedCaptionSource)
        guard !Task.isCancelled, engine == .apple else { return }
        appleLanguages = languages
        if !languages.isEmpty, let target = choice.target, !languages.contains(where: { $0.target == target }) {
            await app.setCaptionTranslation(.off)
        }
    }

    @ViewBuilder private var modelDownload: some View {
        switch app.setup.translationModels {
        case .downloading(let fraction):
            Text("Downloading translation model… \(Int(fraction * 100))%")
                .font(Typo.caption).foregroundStyle(Palette.muted).monospacedDigit()
        case .failed:
            HStack {
                Text("Couldn't download the translation model.").font(Typo.caption).foregroundStyle(Palette.muted)
                Spacer()
                PillButton("Retry", icon: "refresh") { Task { await app.setup.downloadTranslationModels() } }
            }
        case .notDownloaded:
            HStack {
                Spacer()
                PillButton("Download", icon: "download") { Task { await app.setup.downloadTranslationModels() } }
            }
        case .downloaded: EmptyView()
        }
    }
}

@available(macOS 26, *)
private struct AppleModelDownload: View {
    let language: AppleCaptionLanguage
    let refresh: () -> Void
    @State private var pending: [String] = []
    @State private var failed = false

    var body: some View {
        HStack {
            if failed {
                Text("Couldn't download the translation model.").font(Typo.caption).foregroundStyle(Palette.muted)
            }
            Spacer()
            if let source = pending.first {
                ProgressView().controlSize(.small)
                    .translationTask(source: .init(identifier: source), target: .init(identifier: language.identifier)) { @Sendable session in
                        do {
                            try await session.prepareTranslation()
                            await MainActor.run {
                                guard !Task.isCancelled, pending.first == source else { return }
                                pending.removeFirst()
                                if pending.isEmpty { refresh() }
                            }
                        } catch {
                            await MainActor.run {
                                guard !Task.isCancelled, pending.first == source else { return }
                                pending = []
                                failed = true
                                refresh()
                            }
                        }
                    }
                    .id(source)
            } else {
                PillButton(failed ? "Retry" : "Download", icon: "download") {
                    failed = false
                    pending = language.missingSources
                }
            }
        }
    }
}
