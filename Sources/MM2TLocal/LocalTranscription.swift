import OSLog
import AVFoundation
import FluidAudio
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

    public static func breezeMLX(in models: URL) -> LocalTranscriptionModel {
        LocalTranscriptionModel(snapshot: ModelSnapshot(
            directory: models.appending(path: "transcription/breeze-asr-25-mlx-fp16"),
            sources: [HubFiles(repo: "schsu/breeze-asr-25-mlx", revision: "6e48985d562fcf19e80daf8bebf84fb994fb3cc7",
                               paths: ["config.json", "weights.safetensors"])],
            approximateBytes: 3_082_909_657))
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
            approximateBytes: 1_114_164_026))
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

    /// One worker per active track of a short, 16 kHz recording window.
    public func transcribeTracks(_ tracks: [[Float]], hints: [String]) async throws -> [[TimedWord]] {
        try await engine.transcribeTracks(tracks, hints: hints, language: language)
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

/// Live captions on this Mac: each clip is decoded from memory by the model the recordings use.
extension LocalTranscription: ClipTranscriber {
    public func prepare() async throws {
        do {
            try await engine.prepare()
        } catch let error as ProviderError {
            throw error.asTranscriptionError
        }
    }

    public func transcribe(clip samples: [Float], request: StreamingTranscriptionRequest) async throws -> String {
        do {
            let clip = Self.resampled(samples, from: request.sampleRate, to: WhisperKit.sampleRate)
            return Alignment.joined(try await engine.transcribe(clip: clip, hints: request.hints, languageCode: request.languageCode))
        } catch let error as ProviderError {
            throw error.asTranscriptionError
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderError(.localTranscription, .audioUnreadable).asTranscriptionError
        }
    }

    /// Linear interpolation; recordings are already at Whisper's 16 kHz, so this is normally a pass-through.
    static func resampled(_ samples: [Float], from rate: Int, to target: Int) -> [Float] {
        guard rate != target, rate > 0, samples.count > 1 else { return samples }
        let step = Double(rate) / Double(target)
        let count = Int(Double(samples.count) / step)
        return (0..<count).map { index in
            let position = Double(index) * step
            let lower = min(Int(position), samples.count - 1), upper = min(lower + 1, samples.count - 1)
            let fraction = Float(position - Double(lower))
            return samples[lower] + (samples[upper] - samples[lower]) * fraction
        }
    }
}

actor WhisperEngine {
    private let folder: URL
    private var whisper: WhisperKit?
    /// One decode at a time: captions and a meeting being processed share the loaded model.
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(folder: URL) {
        self.folder = folder
    }

    /// With no language code Whisper detects the language itself from the first window.
    func transcribe(audio: URL, hints: [String], language: TranscriptionLanguage) async throws -> [TimedWord] {
        try await exclusively {
            let whisper = try await load()
            let options = recordingOptions(language: language, hints: hints, whisper: whisper)
            return Self.words(try await whisper.transcribe(audioPath: audio.path, decodeOptions: options).flatMap(\.segments))
        }
    }

    private func recordingOptions(language: TranscriptionLanguage, hints: [String], whisper: WhisperKit) -> DecodingOptions {
        var options = DecodingOptions(
            task: .transcribe, language: language.code, temperatureFallbackCount: 3, usePrefillPrompt: true,
            detectLanguage: language.code == nil, skipSpecialTokens: true, wordTimestamps: true, chunkingStrategy: .vad)
        options.promptTokens = Self.promptTokens(hints, tokenizer: whisper.tokenizer)
        return options
    }

    func transcribeTracks(_ tracks: [[Float]], hints: [String], language: TranscriptionLanguage) async throws -> [[TimedWord]] {
        guard !tracks.isEmpty else { return [] }
        return try await exclusively {
            let whisper = try await load()
            var options = recordingOptions(language: language, hints: hints, whisper: whisper)
            options.concurrentWorkerCount = tracks.count
            let results = await whisper.transcribeWithResults(audioArrays: tracks, decodeOptions: options)
            guard results.count == tracks.count else { throw ProviderError(.localTranscription, .audioUnreadable) }
            return try results.map { Self.words(try $0.get().flatMap(\.segments)) }
        }
    }

    /// Loading runs under the same lock as decoding, so callers arriving together load the model once.
    func prepare() async throws {
        guard whisper == nil else { return }
        try await exclusively { _ = try await load() }
    }

    /// A clip under 30 s is one Whisper window: no chunking or word timings, and a single
    /// temperature fallback, so a caption is never held up by retries.
    func transcribe(clip: [Float], hints: [String], languageCode: String?) async throws -> [TimedWord] {
        try await exclusively {
            let whisper = try await load()
            var options = DecodingOptions(
                task: .transcribe, language: languageCode, temperatureFallbackCount: 1, usePrefillPrompt: true,
                detectLanguage: languageCode == nil, skipSpecialTokens: true, withoutTimestamps: true)
            options.promptTokens = Self.promptTokens(hints, tokenizer: whisper.tokenizer)
            return Self.words(try await whisper.transcribe(audioArray: clip, decodeOptions: options).flatMap(\.segments))
        }
    }

    private func exclusively<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        while isBusy { await withCheckedContinuation { waiting.append($0) } }
        isBusy = true
        defer {
            isBusy = false
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        return try await body()
    }

    private func load() async throws -> WhisperKit {
        if let whisper { return whisper }
        guard FileManager.default.fileExists(atPath: folder.appending(path: "TextDecoder.mlmodelc").path) else {
            throw ProviderError(.localTranscription, .modelUnavailable)
        }
        do {
            let config = WhisperKitConfig(
                modelFolder: folder.path, tokenizerFolder: folder,
                // Match the released Core ML configuration so both models can reuse their specializations.
                computeOptions: ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine),
                verbose: false, logLevel: .error, prewarm: false, load: true, download: false)
            let whisper = try await WhisperKit(config)
            let times = whisper.currentTimings
            Logger(subsystem: "dev.mm2t.app", category: "Transcription").info("event=breeze_ready model_s=\(times.modelLoading, privacy: .public) decoder_s=\(times.decoderLoadTime, privacy: .public) encoder_s=\(times.encoderLoadTime, privacy: .public) tokenizer_s=\(times.tokenizerLoadTime, privacy: .public)")
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

/// Reads bounded 16 kHz blocks and restores their timestamps to the recording timeline.
func transcribeAudioWindows(_ audio: URL, decode: ([Float]) async throws -> [TimedWord]) async throws -> TranscribedWords {
    let file = try AVAudioFile(forReading: audio)
    let converter = AudioConverter()
    let format = file.processingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * 30)) else {
        throw TranscriptionError.failed("Unable to read audio.")
    }
    var result: [TimedWord] = []
    while file.framePosition < file.length {
        try Task.checkCancellation()
        let offset = Double(file.framePosition) / format.sampleRate
        try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), file.length - file.framePosition)))
        guard buffer.frameLength > 0 else { throw TranscriptionError.failed("Incomplete audio.") }
        let words = try await decode(converter.resampleBuffer(buffer))
        result += words.map { TimedWord(text: $0.text, range: .init(start: $0.range.start + offset, end: $0.range.end + offset)) }
    }
    return .unlabeled(result)
}

/// Cancelling a queued caller must not wait for another recording that owns the decoder.
func cancellableInference<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let (results, continuation) = AsyncThrowingStream<T, Error>.makeStream()
    let task = Task {
        do {
            try Task.checkCancellation()
            let result = try await operation()
            continuation.yield(result)
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
    continuation.onTermination = { @Sendable reason in
        if case .cancelled = reason { task.cancel() }
    }
    var iterator = results.makeAsyncIterator()
    guard let result = try await iterator.next() else { throw CancellationError() }
    try Task.checkCancellation()
    return result
}
