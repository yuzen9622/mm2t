import AVFoundation
import CoreML
import FluidAudio
import Foundation
import MM2TCore
import MM2TProviders

public enum LocalSpeechModel: String, CaseIterable, Codable, Sendable {
    case breeze, breezeCoreML, parakeet, nemotron, whisperCPU

    public func isSupported(on machine: MachineProfile) -> Bool {
        switch self {
        case .whisperCPU: true
        case .breeze: machine.isAppleSilicon  // The helper runs as a separate arm64 process.
        case .breezeCoreML, .parakeet, .nemotron: machine.isAppleSilicon && !machine.isTranslated
        }
    }

    public var isBreeze: Bool { self == .breeze || self == .breezeCoreML }

    public var name: String {
        switch self {
        case .whisperCPU: "Whisper Base (CPU)"
        case .breezeCoreML: "Breeze-ASR-25 Core ML"
        case .breeze: "Breeze-ASR-25 MLX"
        case .parakeet: "Parakeet TDT v3"
        case .nemotron: "Nemotron 3.5 Multilingual"
        }
    }

    public func snapshot(in models: URL) -> ModelSnapshot {
        switch self {
        case .whisperCPU:
            return ModelSnapshot(directory: models.appending(path: "transcription/whisper-base-cpu"),
                sources: [HubFiles(repo: "ggerganov/whisper.cpp", revision: "5359861c739e955e79d9a303bcbc70fb988958b1",
                                   paths: [WhisperCPU.modelFile])], approximateBytes: 147_951_465)
        case .breezeCoreML: return LocalTranscriptionModel.breeze(in: models).snapshot
        case .breeze: return LocalTranscriptionModel.breezeMLX(in: models).snapshot
        case .parakeet:
            return ModelSnapshot(directory: models.appending(path: "transcription/parakeet-v3"),
                sources: [HubFiles(repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
                    revision: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
                    paths: ["Encoder.mlmodelc/", "Decoder.mlmodelc/", "Preprocessor.mlmodelc/", "JointDecisionv3.mlmodelc/", "parakeet_vocab.json"])],
                approximateBytes: 483_105_645)
        case .nemotron:
            return ModelSnapshot(directory: models.appending(path: "transcription/nemotron-3.5"),
                sources: [HubFiles(repo: "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML",
                    revision: "aeae878bb403f420e602214624df5a4e7ba816b0", paths: ["multilingual/1120ms/"])],
                approximateBytes: 664_007_130)
        }
    }
}

public actor ParakeetTranscription: TranscriptionProvider, ClipTranscriber {
    private let directory: URL
    private var manager: AsrManager?

    public init(directory: URL) { self.directory = directory }

    private func loaded() throws -> AsrManager {
        if let manager { return manager }
        let model: AsrModels
        do {
            model = try AsrModels.loadLocal(from: directory)
        } catch {
            throw ProviderError(.localTranscription, .modelUnavailable).asTranscriptionError
        }
        let manager = AsrManager(models: model)
        self.manager = manager
        return manager
    }

    public func prepare() async throws { _ = try loaded() }

    public func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) async throws -> TranscribedWords {
        let manager = try loaded()
        var state = try TdtDecoderState(decoderLayers: AsrModelVersion.v3.decoderLayers)
        let result = try await manager.transcribe(audio, decoderState: &state)
        let words = buildWordTimings(from: result.tokenTimings ?? [])
        return .unlabeled(words.map { TimedWord($0.word, $0.startTime, $0.endTime) })
    }

    public func transcribe(clip samples: [Float], request: StreamingTranscriptionRequest) async throws -> String {
        var state = try TdtDecoderState(decoderLayers: AsrModelVersion.v3.decoderLayers)
        let clip = LocalTranscription.resampled(samples, from: request.sampleRate, to: 16_000)
        return try await loaded().transcribe(clip, decoderState: &state).text
    }
}

public struct NemotronTranscription: TranscriptionProvider, StreamingTranscriptionProvider {
    let directory: URL
    let language: String?
    let cpuOnly: Bool
    public init(directory: URL, language: String? = nil, cpuOnly: Bool = false) {
        self.cpuOnly = cpuOnly
        self.directory = directory
        self.language = language
    }

    private func manager(language: String?) async throws -> StreamingNemotronMultilingualAsrManager {
        let configuration: MLModelConfiguration?
        if cpuOnly {
            let cpu = MLModelConfiguration()
            cpu.computeUnits = .cpuOnly
            configuration = cpu
        } else { configuration = nil }
        let manager = StreamingNemotronMultilingualAsrManager(configuration: configuration)
        do {
            try await manager.loadModels(from: directory.appending(path: "multilingual/1120ms"))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderError(.localTranscription, .modelUnavailable).asTranscriptionError
        }
        // The multilingual weights emit unknown tokens with the reserved zh-TW prompt.
        await manager.setLanguage(language == "zh" ? "zh-CN" : language)
        return manager
    }

    public func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) async throws -> TranscribedWords {
        let manager = try await manager(language: language)
        let file = try AVAudioFile(forReading: audio)
        let converter = AudioConverter()
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * 10)) else {
            throw TranscriptionError.failed("Unable to read audio.")
        }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), file.length - file.framePosition)))
            guard buffer.frameLength > 0 else { break }
            _ = try await manager.process(samples: converter.resampleBuffer(buffer))
        }
        let result = try await manager.finishWithTokenTimings()
        let words = buildWordTimings(from: result.timings).map { TimedWord($0.word, $0.startTime, $0.endTime) }
        let detected = await manager.detectedLanguage()
        return .unlabeled(TaiwaneseTranscript.convert(words, language: language ?? detected))
    }

    public func open(_ request: StreamingTranscriptionRequest) async throws -> any StreamingTranscriptionSession {
        try await NemotronSession(manager: manager(language: request.languageCode), rate: request.sampleRate, language: request.languageCode)
    }
}

private actor NemotronSession: StreamingTranscriptionSession {
    nonisolated let events: AsyncThrowingStream<StreamingTranscriptEvent, Error>
    let output: AsyncThrowingStream<StreamingTranscriptEvent, Error>.Continuation
    let manager: StreamingNemotronMultilingualAsrManager
    let rate: Int
    let language: String?
    var previous = ""
    var quietSamples = 0
    var segmentSamples = 0
    var closed = false
    private var sending = false
    private var waitingToClose: CheckedContinuation<Void, Never>?

    init(manager: StreamingNemotronMultilingualAsrManager, rate: Int, language: String?) {
        (events, output) = AsyncThrowingStream.makeStream()
        self.manager = manager
        self.language = language
        self.rate = rate
    }

    func send(_ samples: [Float]) async throws {
        guard !closed, !samples.isEmpty else { return }
        // CaptionStream has one audio producer. A pause can close the session while
        // that producer is suspended inside Core ML.
        sending = true
        defer {
            sending = false
            waitingToClose?.resume()
            waitingToClose = nil
        }
        let clip = LocalTranscription.resampled(samples, from: rate, to: 16_000)
        let energy = clip.reduce(Float.zero) { $0 + $1 * $1 }
        quietSamples = energy < 0.000025 * Float(clip.count) ? quietSamples + clip.count : 0
        segmentSamples += clip.count
        _ = try await manager.process(samples: clip)
        guard !closed else { return }
        let partial = await manager.getPartialTranscript()
        if !partial.isEmpty, partial != previous {
            previous = partial
            output.yield(.partial(await localized(partial)))
        }
        if (quietSamples >= 11_200 && segmentSamples > quietSamples) || segmentSamples >= 320_000 {
            try await settle()
            await manager.reset()
        }
    }

    private func localized(_ text: String) async -> String {
        let detected = await manager.detectedLanguage()
        return TaiwaneseTranscript.convert(text, language: language ?? detected)
    }

    private func settle() async throws {
        let final = try await manager.finish()
        if !final.isEmpty { output.yield(.final(await localized(final))) }
        previous = ""
        quietSamples = 0
        segmentSamples = 0
    }

    func discard() {
        guard !closed else { return }
        closed = true
        output.finish()
    }

    func close() async {
        guard !closed else { return }
        closed = true
        if sending {
            await withCheckedContinuation { waitingToClose = $0 }
        }
        do {
            if segmentSamples > 0 { try await settle() }
            output.finish()
        } catch { output.finish(throwing: error) }
    }
}
