import CoreML
import Foundation
import MM2TCore
import MM2TProviders
import WhisperKit

/// A WhisperKit CoreML model folder plus its tokenizer files.
public struct LocalTranscriptionModel: Sendable {
    public let snapshot: ModelSnapshot

    public init(snapshot: ModelSnapshot) {
        self.snapshot = snapshot
    }

    /// MediaTek's Breeze-ASR-25 (Whisper large-v2 fine-tuned on Taiwanese Mandarin and Mandarin-English
    /// code-switching), 4-bit palettized for the Neural Engine, about 1.1 GB. The tokenizer comes from
    /// MediaTek's repo so loading never reaches the network.
    public static func breeze(in models: URL) -> LocalTranscriptionModel {
        LocalTranscriptionModel(snapshot: ModelSnapshot(
            directory: models.appending(path: "transcription/breeze-asr-25-4bit"),
            sources: [
                HubFiles(
                    repo: "weiren119/Breeze-ASR-25-coreml-4bit-palette", revision: "3fc162355f3460de6b1e53518a1678cea06464d9",
                    paths: ["AudioEncoder.mlmodelc/", "MelSpectrogram.mlmodelc/", "TextDecoder.mlmodelc/", "config.json", "generation_config.json"]),
                HubFiles(
                    repo: "MediaTek-Research/Breeze-ASR-25", revision: "cffe7ccb404d025296a00758d0a33468bec3a9d0",
                    paths: ["tokenizer.json", "tokenizer_config.json"]),
            ],
            approximateBytes: 1_110_000_000))
    }
}

/// On-device transcription with WhisperKit, the last source in the chain: it cannot be
/// unreachable, so every failure stops the chain with a message. Loads the model on first use.
public struct LocalTranscription: TranscriptionProvider {
    let engine: WhisperEngine
    let language: TranscriptionLanguage

    public init(model: LocalTranscriptionModel, language: TranscriptionLanguage = .auto) {
        engine = WhisperEngine(folder: model.snapshot.directory)
        self.language = language
    }

    private init(engine: WhisperEngine, language: TranscriptionLanguage) {
        self.engine = engine
        self.language = language
    }

    /// The same loaded model told to expect another language; loading it takes minutes, so it is shared.
    public func speaking(_ language: TranscriptionLanguage) -> LocalTranscription {
        LocalTranscription(engine: engine, language: language)
    }

    public func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) async throws -> TranscribedWords {
        do {
            return .unlabeled(try await engine.transcribe(audio: audio, hints: hints, language: language))
        } catch let error as ProviderError {
            throw error.asTranscriptionError
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderError(.localTranscription, .audioUnreadable).asTranscriptionError
        }
    }
}

actor WhisperEngine {
    private let folder: URL
    private var whisper: WhisperKit?

    init(folder: URL) {
        self.folder = folder
    }

    /// With no language code Whisper detects the language itself from the first window.
    func transcribe(audio: URL, hints: [String], language: TranscriptionLanguage) async throws -> [TimedWord] {
        let whisper = try await load()
        var options = DecodingOptions(
            task: .transcribe, language: language.code, temperatureFallbackCount: 3, usePrefillPrompt: true,
            detectLanguage: language.code == nil, skipSpecialTokens: true, wordTimestamps: true, chunkingStrategy: .vad)
        options.promptTokens = Self.promptTokens(hints, tokenizer: whisper.tokenizer)
        let results = try await whisper.transcribe(audioPath: audio.path, decodeOptions: options)
        return Self.words(results.flatMap(\.segments))
    }

    private func load() async throws -> WhisperKit {
        if let whisper { return whisper }
        guard FileManager.default.fileExists(atPath: folder.appending(path: "TextDecoder.mlmodelc").path) else {
            throw ProviderError(.localTranscription, .modelUnavailable)
        }
        do {
            let config = WhisperKitConfig(
                modelFolder: folder.path, tokenizerFolder: folder,
                computeOptions: ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine),
                verbose: false, logLevel: .error, prewarm: false, load: true, download: false)
            let whisper = try await WhisperKit(config)
            self.whisper = whisper
            return whisper
        } catch {
            throw ProviderError(.localTranscription, .modelUnavailable)
        }
    }

    /// Whisper reads the prompt as the text that came before, so names and terms listed there are
    /// spelled the way the user wrote them. Kept well under the decoder's 224-token prompt window.
    static func promptTokens(_ hints: [String], tokenizer: (any WhisperTokenizer)?) -> [Int]? {
        guard let tokenizer, !hints.isEmpty else { return nil }
        let tokens = tokenizer.encode(text: " " + hints.joined(separator: "、"))
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return tokens.isEmpty ? nil : Array(tokens.prefix(120))
    }

    /// Word timings when the model produced them, otherwise one entry per segment.
    static func words(_ segments: [TranscriptionSegment]) -> [TimedWord] {
        segments.sorted { $0.start < $1.start }.flatMap { segment -> [TimedWord] in
            let words = (segment.words ?? []).compactMap { word -> TimedWord? in
                let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !text.hasPrefix("<|") else { return nil }
                return TimedWord(text, seconds(word.start), seconds(max(word.end, word.start)))
            }
            if !words.isEmpty { return words }
            let text = segment.text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [TimedWord(text, seconds(segment.start), seconds(segment.end))]
        }
    }

    /// Whisper times are Float; milliseconds keep `0.2` from becoming `0.20000000298`.
    private static func seconds(_ value: Float) -> TimeInterval {
        (Double(value) * 1_000).rounded() / 1_000
    }
}
