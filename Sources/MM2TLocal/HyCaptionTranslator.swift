import Foundation
import MM2TCore

public struct HyCaptionTranslator: CaptionTranslator {
    private let engine: LlamaEngine
    private static let targetNames = Dictionary(uniqueKeysWithValues: CaptionTarget.hyTargets.compactMap { target -> (String, String)? in
        switch target.code {
        case "zh_hant": return (target.code, "Traditional Chinese")
        case "zh": return (target.code, "Simplified Chinese")
        default: return Locale(identifier: "en").localizedString(forLanguageCode: target.code).map { (target.code, $0) }
        }
    })

    public init(models: HyTranslationModels) {
        engine = LlamaEngine(path: models.file, contextTokens: 8_192)
    }

    public func translate(_ text: String, through languages: [String]) async throws -> String {
        guard let source = languages.first, let target = languages.last,
              Self.targetNames[source] != nil, let name = Self.targetNames[target] else {
            throw HyTranslationError.unsupportedLanguage
        }
        guard source != target, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        let prompt = "<｜hy_begin▁of▁sentence｜><｜hy_User｜>Translate the following text into \(name). Note that you should only output the translated result without any additional explanation:\n\n\(text)<｜hy_Assistant｜>"
        let result = try await engine.generate(prompt: prompt, using: .hyTranslation).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw HyTranslationError.emptyTranslation }
        return target == "zh_hant" ? TraditionalChinese.convert(result) : result
    }
}

private enum HyTranslationError: Error {
    case unsupportedLanguage, emptyTranslation
}
