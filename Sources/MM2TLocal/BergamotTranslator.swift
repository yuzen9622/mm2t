import Bergamot
import Foundation
import MM2TCore

public enum CaptionTranslationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No installed model translates this way.
    case unsupported(CaptionLanguage, CaptionLanguage)
    case engine(String)

    public var description: String {
        switch self {
        case .unsupported(let source, let target): "no translation model from \(source) to \(target)"
        case .engine(let reason): reason
        }
    }
}

/// Live caption translation on this Mac with Mozilla's Bergamot engine. Loads a direction's model
/// on first use and keeps it until `unload()` (the recording stopped) or until the other direction
/// is asked for; one model is in memory at a time. Runs on this actor, never on the main thread.
public actor BergamotTranslator: CaptionTranslator {
    private let models: TranslationModels
    private var loaded: LoadedModel?

    public init(models: TranslationModels) {
        self.models = models
    }

    public func translate(_ text: String, from source: CaptionLanguage, to target: CaptionLanguage) throws -> String {
        let handle = try load(from: source, to: target).handle
        var error: UnsafeMutablePointer<CChar>?
        guard let output = mm2t_bergamot_translate(handle, text, &error) else {
            throw CaptionTranslationError.engine(Self.take(error) ?? "translation failed")
        }
        defer { mm2t_bergamot_string_free(output) }
        return String(cString: output)
    }

    /// Frees the model; the next translation loads it again.
    public func unload() {
        loaded = nil
    }

    private func load(from source: CaptionLanguage, to target: CaptionLanguage) throws -> LoadedModel {
        if let loaded, loaded.direction.source == source, loaded.direction.target == target { return loaded }
        guard let direction = models.direction(from: source, to: target) else {
            throw CaptionTranslationError.unsupported(source, target)
        }
        unload()
        let paths = models.paths(direction)
        var error: UnsafeMutablePointer<CChar>?
        guard let handle = mm2t_bergamot_model_create(
            paths.model.path, paths.shortlist.path, paths.sourceVocabulary.path, paths.targetVocabulary.path, &error) else {
            throw CaptionTranslationError.engine(Self.take(error) ?? "the translation model did not load")
        }
        let model = LoadedModel(direction: direction, handle: handle)
        loaded = model
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
