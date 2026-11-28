import CWhisperCPU
import Foundation
import MM2TCore
import MM2TProviders

/// Multilingual Whisper with whisper.cpp's CPU backend. Captions and recorded audio share the model.
public struct WhisperCPU: TranscriptionProvider, ClipTranscriber {
    static let modelFile = "ggml-base.bin"
    private let decoder: Decoder
    private let language: TranscriptionLanguage

    public init(folder: URL) {
        decoder = Decoder(file: folder.appending(path: Self.modelFile))
        language = .auto
    }

    private init(decoder: Decoder, language: TranscriptionLanguage) {
        self.decoder = decoder
        self.language = language
    }

    public func speaking(_ language: TranscriptionLanguage) -> Self { Self(decoder: decoder, language: language) }
    public func prepare() async throws { try await cancellableInference { try await decoder.prepare() } }

    public func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) async throws -> TranscribedWords {
        try await transcribeAudioWindows(audio) { samples in
            try await decoder.decode(samples, language: language.code, hints: hints)
        }
    }

    public func transcribe(clip: [Float], request: StreamingTranscriptionRequest) async throws -> String {
        let pcm = LocalTranscription.resampled(clip, from: request.sampleRate, to: 16_000)
        return Alignment.joined(try await decoder.decode(pcm, language: request.languageCode, hints: request.hints))
    }
}

private actor Decoder {
    private nonisolated let queue = DispatchSerialQueue(label: "dev.mm2t.whisper.cpu")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private final class Model {
        let context: OpaquePointer

        init(file: URL) throws {
            guard let context = mm2t_whisper_load(file.path) else {
                throw ProviderError(.localTranscription, .modelUnavailable).asTranscriptionError
            }
            self.context = context
        }

        deinit { mm2t_whisper_free(context) }
    }

    private let file: URL
    private var model: Model?

    init(file: URL) { self.file = file }

    func prepare() throws {
        try Task.checkCancellation()
        if model == nil { model = try Model(file: file) }
    }

    nonisolated func decode(_ samples: [Float], language: String?, hints: [String]) async throws -> [TimedWord] {
        let cancelled = Flag()
        return try await withTaskCancellationHandler {
            try await cancellableInference { try await self.words(samples, language: language, hints: hints, cancelled: cancelled) }
        } onCancel: { cancelled.set(true) }
    }

    private func words(_ samples: [Float], language: String?, hints: [String], cancelled: Flag) throws -> [TimedWord] {
        // A muted PCM16 track may contain only zeros or one rounding bit after conversion.
        // Sending that window to Whisper can invent a speaker on a silent microphone.
        try Task.checkCancellation()
        guard samples.contains(where: { abs($0) > 1.0 / 32_768 }) else { return [] }
        try prepare()
        guard let context = model?.context else { throw ProviderError(.localTranscription, .modelUnavailable).asTranscriptionError }
        try Task.checkCancellation()
        let count = mm2t_whisper_decode(context, samples, Int32(samples.count), language ?? "auto",
                                        hints.joined(separator: "、"), { state in
            Unmanaged<Flag>.fromOpaque(state!).takeUnretainedValue().get
        }, Unmanaged.passUnretained(cancelled).toOpaque())
        try Task.checkCancellation()
        guard count >= 0 else { throw TranscriptionError.failed("Whisper CPU transcription failed.") }
        var result: [TimedWord] = []
        let duration = Double(samples.count) / 16_000
        for index in 0..<count {
            var start: Int64 = 0, end: Int64 = 0
            guard let segment = mm2t_whisper_segment(context, index, &start, &end) else { continue }
            let from = min(duration, max(0, Double(start) / 100))
            let until = min(duration, max(from, Double(end) / 100))
            var tokens = WhisperWords()
            for token in 0..<mm2t_whisper_token_count(context, index) {
                var t0: Int64 = 0, t1: Int64 = 0
                guard let bytes = mm2t_whisper_token(context, index, token, &t0, &t1) else { continue }
                let lower = min(until, max(from, Double(t0) / 100))
                let upper = min(until, max(lower, Double(t1) / 100))
                tokens.append(bytes: UnsafeRawBufferPointer(start: bytes, count: strlen(bytes)), start: lower, end: upper)
            }
            let words = tokens.finish()
            if words.isEmpty {
                let text = String(cString: segment).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { result.append(TimedWord(text, from, until)) }
            } else {
                result += words
            }
        }
        return result
    }
}

/// Whisper tokens can split a UTF-8 scalar or an English word. Keep both intact for alignment.
struct WhisperWords {
    private var bytes = Data()
    private var byteStart = 0.0
    private var pendingSpace = false
    private var word = ""
    private var wordStart = 0.0
    private var wordEnd = 0.0
    private var words: [TimedWord] = []

    mutating func append(bytes token: UnsafeRawBufferPointer, start: Double, end: Double) {
        if bytes.isEmpty { byteStart = start }
        bytes.append(contentsOf: token)
        guard let text = String(data: bytes, encoding: .utf8) else { return }
        bytes.removeAll(keepingCapacity: true)
        for character in text {
            if character.isWhitespace {
                flush()
                pendingSpace = true
                continue
            }

            // Han and kana have no required space between words. Preserve their token times,
            // while keeping punctuation inside strings such as "3.14" and "example.com".
            let separate = character.unicodeScalars.first?.properties.isIdeographic == true
                || (!character.isASCII && String(character).wholeMatch(of: /[\p{Hiragana}\p{Katakana}]/) != nil)
            if separate { flush() }
            if word.isEmpty {
                wordStart = byteStart
                if pendingSpace && !words.isEmpty { word = " " }
            }
            pendingSpace = false
            word.append(character)
            wordEnd = end
            if separate { flush() }
        }
    }

    mutating func finish() -> [TimedWord] {
        flush()
        return words
    }

    private mutating func flush() {
        if !word.isEmpty { words.append(TimedWord(word, wordStart, wordEnd)) }
        word = ""
    }
}
