import Foundation
import MM2TCore
import Translation

/// A target the system can reach from both caption sources. A pair absent from
/// `missingSources` is ready, including routes that need no translation model.
public struct AppleCaptionLanguage: Sendable {
    public let target: CaptionTarget
    public let identifier: String
    public let missingSources: [String]
}

public struct AppleCaptionTranslator: CaptionTranslator {
    public init() {}

    public static var isAvailable: Bool {
        if #available(macOS 26, *) { true } else { false }
    }

    public static func languages(source: CaptionLanguage? = nil) async -> [AppleCaptionLanguage] {
        guard #available(macOS 26, *) else { return [] }
        let system = LanguageAvailability()
        var choices: [AppleCaptionLanguage] = []
        for language in await system.supportedLanguages {
            if Task.isCancelled { return [] }
            guard let target = CaptionTarget(languageCode: language.minimalIdentifier),
                  !choices.contains(where: { $0.target == target }) else { continue }
            if let choice = await availability(of: target, source: source, system: system) { choices.append(choice) }
        }
        return choices.sorted { $0.target.name.localizedStandardCompare($1.target.name) == .orderedAscending }
    }

    public static func isInstalled(for target: CaptionTarget, source: CaptionLanguage? = nil) async -> Bool {
        guard #available(macOS 26, *) else { return false }
        return await availability(of: target, source: source, system: LanguageAvailability())?.missingSources.isEmpty == true
    }

    @available(macOS 26, *)
    private static func availability(of target: CaptionTarget, source: CaptionLanguage?, system: LanguageAvailability) async -> AppleCaptionLanguage? {
        let id = target.code.replacingOccurrences(of: "_", with: "-")
        let destination = Locale.Language(identifier: id)
        var missing: [String] = []
        var supported = true
        for source in source.map({ [$0] }) ?? CaptionLanguage.allCases {
            guard case .models = target.route(from: source, engine: .apple) else { continue }
            let from = source == .english ? "en" : "zh-Hant"
            switch await system.status(from: .init(identifier: from), to: destination) {
            case .installed: break
            case .supported: missing.append(from)
            default: supported = false
            }
        }
        return supported ? .init(target: target, identifier: id, missingSources: missing) : nil
    }

    public func translate(_ text: String, through languages: [String]) async throws -> String {
        guard #available(macOS 26, *), let first = languages.first, let last = languages.last else {
            throw CocoaError(.featureUnsupported)
        }
        let source = Locale.Language(identifier: first.replacingOccurrences(of: "_", with: "-"))
        let target = Locale.Language(identifier: last.replacingOccurrences(of: "_", with: "-"))
        let session = TranslationSession(installedSource: source, target: target)
        return try await session.translate(text).targetText
    }
}
