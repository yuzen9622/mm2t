import Bergamot
import Foundation
import MM2TCore

public enum CaptionTranslationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No model translates this way.
    case unsupported(ModelPair)
    case engine(String)

    public var description: String {
        switch self {
        case .unsupported(let pair): "no translation model for \(pair)"
        case .engine(let reason): reason
        }
    }
}

/// Live caption translation on this Mac with Mozilla's Bergamot engine. Loads each model it is
/// asked to use on first use and keeps it until `unload()` or until the translator goes, which is
/// when the recording's captions end. A recording uses one target language, so at most the models
/// of that language's routes are ever in memory (two when Chinese is pivoted through English).
/// Runs on this actor, never on the main thread.
public actor BergamotTranslator: CaptionTranslator {
    private let models: TranslationModels
    private var loaded: [ModelPair: LoadedModel] = [:]

    public init(models: TranslationModels) {
        self.models = models
    }

    public func translate(_ text: String, through languages: [String]) throws -> String {
        var current = text
        for pair in zip(languages, languages.dropFirst()).map(ModelPair.init) {
            current = try translate(current, with: load(pair).handle)
        }
        return current
    }

    /// Frees every model; the next translation loads what it needs again.
    public func unload() {
        loaded = [:]
    }

    private func translate(_ text: String, with handle: OpaquePointer) throws -> String {
        var error: UnsafeMutablePointer<CChar>?
        guard let output = mm2t_bergamot_translate(handle, text, &error) else {
            throw CaptionTranslationError.engine(Self.take(error) ?? "translation failed")
        }
        defer { mm2t_bergamot_string_free(output) }
        return String(cString: output)
    }

    private func load(_ pair: ModelPair) throws -> LoadedModel {
        if let model = loaded[pair] { return model }
        guard let direction = models.direction(pair) else { throw CaptionTranslationError.unsupported(pair) }
        let paths = models.paths(direction)
        var error: UnsafeMutablePointer<CChar>?
        // The zh_hant→en shortlist excludes valid continuations of terms such as “single sign-on”.
        let shortlist = pair == ModelPair("zh_hant", "en") ? nil : paths.shortlist.path
        guard let handle = mm2t_bergamot_model_create(
            paths.model.path, shortlist, paths.sourceVocabulary.path, paths.targetVocabulary.path, &error) else {
            throw CaptionTranslationError.engine(Self.take(error) ?? "the translation model did not load")
        }
        let model = LoadedModel(direction: direction, handle: handle)
        loaded[pair] = model
        return model
    }

    private static func take(_ error: UnsafeMutablePointer<CChar>?) -> String? {
        guard let error else { return nil }
        defer { mm2t_bergamot_string_free(error) }
        return String(cString: error)
    }
}

/// Owns one engine model and frees it with the last reference. Only `BergamotTranslator` touches it.
private final class LoadedModel: @unchecked Sendable {
    let direction: TranslationDirection
    let handle: OpaquePointer

    init(direction: TranslationDirection, handle: OpaquePointer) {
        self.direction = direction
        self.handle = handle
    }

    deinit { mm2t_bergamot_model_free(handle) }
}
