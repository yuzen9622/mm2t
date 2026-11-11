import FluidAudio
import Foundation

public enum DiarizationModelError: Error, Equatable, Sendable {
    /// The models are not on disk. Diarizing never downloads; the app calls `DiarizationModels.download`.
    case missing(directory: URL)
    case downloadFailed(String)
}

/// Where the Nemotron-3 offline diarizer and the WeSpeaker embedding model live, in FluidAudio's
/// cache layout (`nemotron-3-diarization/`, `speaker-diarization/`), about 210 MB together.
public struct DiarizationModels: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/mm2t/Models` (inside the container when sandboxed).
    public static var applicationSupport: DiarizationModels {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DiarizationModels(directory: base.appending(path: "mm2t/Models"))
    }

    public var isDownloaded: Bool { nemotronIsComplete && weSpeakerIsComplete }

    /// Fetches whichever model is missing from Hugging Face. `progress` receives 0...1.
    /// Throws `DiarizationModelError.downloadFailed`; partial files resume on the next call.
    public func download(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        do {
            if !nemotronIsComplete {
                _ = try await Nemotron3Models.loadFromHuggingFace(
                    config: .offline, cacheDirectory: directory,
                    progressHandler: { progress(0.9 * $0.fractionCompleted) })
            }
            progress(0.9)
            if !weSpeakerIsComplete {
                _ = try await OfflineDiarizerModels.load(
                    from: directory, progressHandler: { progress(0.9 + 0.1 * $0.fractionCompleted) })
            }
        } catch {
            throw DiarizationModelError.downloadFailed(String(describing: error))
        }
        guard isDownloaded else { throw DiarizationModelError.downloadFailed("models incomplete after download") }
        progress(1)
    }

    func loadNemotron() async throws -> Nemotron3Models {
        guard nemotronIsComplete else { throw DiarizationModelError.missing(directory: directory) }
        // With the bundle, assets and weights marker present this only loads; it never downloads.
        return try await Nemotron3Models.loadFromHuggingFace(config: .offline, cacheDirectory: directory)
    }

    func loadWeSpeaker() async throws -> OfflineDiarizerModels {
        guard weSpeakerIsComplete else { throw DiarizationModelError.missing(directory: directory) }
        return try await OfflineDiarizerModels.load(from: directory)
    }

    /// Mirrors what `Nemotron3Models.loadFromHuggingFace` accepts without fetching: a compiled
    /// bundle, the silence embedding, and a weights marker for the current checkpoint (an older
    /// marker makes FluidAudio delete the cache and download again).
    private var nemotronIsComplete: Bool {
        let repo = directory.appending(path: Repo.nemotron3Diarization.folderName)
        let config = Nemotron3Config.offline
        let marker = try? String(
            contentsOf: repo.appending(path: ModelNames.Nemotron3.weightsVersionFile), encoding: .utf8)
        return marker?.trimmingCharacters(in: .whitespacesAndNewlines) == ModelNames.Nemotron3.weightsVersion
            && exists(repo.appending(path: "\(config.hubSubdirectory)/\(config.modelFileName)/coremldata.bin"))
            && exists(repo.appending(path: ModelNames.Nemotron3.silenceEmbeddingFile))
    }

    /// Mirrors FluidAudio's `ModelHub` cache check: pinned revision marker plus every required file.
    private var weSpeakerIsComplete: Bool {
        let repo = directory.appending(path: Repo.diarizer.folderName)
        let revision = try? String(contentsOf: repo.appending(path: ".fluidaudio-revision"), encoding: .utf8)
        guard revision?.trimmingCharacters(in: .whitespacesAndNewlines) == Repo.diarizer.revision else { return false }
        return ModelNames.OfflineDiarizer.requiredModels.allSatisfy { name in
            exists(repo.appending(path: name.hasSuffix(".mlmodelc") ? "\(name)/coremldata.bin" : name))
        }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}
