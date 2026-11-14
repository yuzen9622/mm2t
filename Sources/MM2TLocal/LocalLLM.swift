import Foundation
import llama
import MM2TCore
import MM2TProviders

/// A GGUF chat model and how to talk to it.
public struct LocalLLMModel: Sendable {
    public let snapshot: ModelSnapshot
    let file: String
    /// Prompt plus answer must fit; the KV cache for it is allocated when the model loads.
    let contextTokens: Int32
    let format: @Sendable (_ system: String, _ user: String) -> String

    var path: URL { snapshot.directory.appending(path: file) }

    /// Qwen3.5 9B instruct, Q4_K_M (5.7 GB): writes Traditional Chinese with English terms intact and,
    /// unlike the 4B model, reads who-addressed-whom correctly for name guesses. Its hybrid attention
    /// keeps a 32k-token cache small; about 7 GB resident while it runs.
    public static func qwen35(in models: URL) -> LocalLLMModel {
        let file = "Qwen3.5-9B-Q4_K_M.gguf"
        return LocalLLMModel(
            snapshot: ModelSnapshot(
                directory: models.appending(path: "llm/qwen3.5-9b-q4_k_m"),
                sources: [HubFiles(repo: "unsloth/Qwen3.5-9B-GGUF", revision: "3885219b6810b007914f3a7950a8d1b469d598a5", paths: [file])],
                approximateBytes: 5_680_522_464),
            file: file, contextTokens: 32_768,
            format: { system, user in
                // An empty think block is how Qwen's own template turns reasoning off.
                "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
            })
    }

    public init(snapshot: ModelSnapshot, file: String, contextTokens: Int32,
                format: @escaping @Sendable (_ system: String, _ user: String) -> String) {
        self.snapshot = snapshot
        self.file = file
        self.contextTokens = contextTokens
        self.format = format
    }
}

/// The four LLM tasks on an on-device model through llama.cpp, with every answer constrained to
/// the task's JSON schema. Loads the model on first use and frees it with the last reference,
/// so it holds memory only while a meeting is being processed.
public struct LocalLLM: LLMProvider, StructuredGenerator {
    let model: LocalLLMModel
    let engine: LlamaEngine

    public init(model: LocalLLMModel) {
        self.model = model
        engine = LlamaEngine(path: model.path, contextTokens: model.contextTokens)
    }

    /// Mandarin runs close to one token per character, and a cleaned chunk is as long as its input,
    /// so a chunk takes well under half the context; the whole-transcript tasks get the rest
    /// minus room for the answer.
    private var tasks: LLMTasks {
        LLMTasks(
            self, cleanChunkCharacters: Int(model.contextTokens) / 8,
            maxInputCharacters: Int(model.contextTokens) * 3 / 4 - 4_096)
    }

    public func inferNames(_ request: NameInferenceRequest) async throws -> [NameGuess] { try await tasks.inferNames(request) }
    public func cleanTranscript(_ transcript: LLMTranscript) async throws -> CleanedTranscript { try await tasks.cleanTranscript(transcript) }
    public func digestPerPerson(_ transcript: LLMTranscript) async throws -> [PersonDigest] { try await tasks.digestPerPerson(transcript) }
    public func summarize(_ request: SummaryRequest) async throws -> Summary { try await tasks.summarize(request) }
    public func rewrite(_ text: String, instruction: String) async throws -> String { try await tasks.rewrite(text, instruction: instruction) }
    public func vocabularyCorrections(from old: String, to new: String) async throws -> [VocabularyCorrection] {
        try await tasks.vocabularyCorrections(from: old, to: new)
    }

    package var service: Service { .localLLM }

    package func generate(system: String, input: String, schema: JSON) async throws -> String {
        let grammar: String
        do {
            grammar = try Grammar.gbnf(for: schema)
        } catch {
            throw ProviderError(.localLLM, .malformedResponse)
        }
        return try await engine.generate(prompt: model.format(system, input), grammar: grammar)
    }
}

/// llama.cpp model and context, used from one serial queue: decoding blocks for minutes, which
/// must not happen on Swift's cooperative threads.
final class LlamaEngine: @unchecked Sendable {
    private let path: URL
    private let contextTokens: Int32
    private let queue = DispatchQueue(label: "mm2t.llama", qos: .userInitiated)
    private let cancelled = Flag()
    private var model: OpaquePointer?
    private var context: OpaquePointer?

    init(path: URL, contextTokens: Int32) {
        self.path = path
        self.contextTokens = contextTokens
    }

    deinit {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    private static let backend: Void = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    func generate(prompt: String, grammar: String) async throws -> String {
        cancelled.set(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result { try self.run(prompt: prompt, grammar: grammar) })
                }
            }
        } onCancel: {
            cancelled.set(true)
        }
    }

    private func load() throws -> (OpaquePointer, OpaquePointer) {
        if let model, let context { return (model, context) }
        guard FileManager.default.fileExists(atPath: path.path) else { throw ProviderError(.localLLM, .modelUnavailable) }
        _ = Self.backend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = -1
        guard let model = llama_model_load_from_file(path.path, modelParams) else {
            throw ProviderError(.localLLM, .modelUnavailable)
        }
        var params = llama_context_default_params()
        params.n_ctx = UInt32(contextTokens)
        params.n_batch = 1_024
        params.n_ubatch = 512
        params.no_perf = true
        guard let context = llama_init_from_model(model, params) else {
            llama_model_free(model)
            throw ProviderError(.localLLM, .modelUnavailable)
        }
        self.model = model
        self.context = context
        return (model, context)
    }

    private func run(prompt: String, grammar: String) throws -> String {
        let (model, context) = try load()
        let vocab = llama_model_get_vocab(model)
        llama_memory_clear(llama_get_memory(context), true)

        let tokens = try tokenize(prompt, vocab: vocab)
        let capacity = Int(llama_n_ctx(context))
        // An answer needs room; a prompt that leaves none is treated like an answer that hit the cap.
        guard tokens.count + 256 < capacity else { throw OutputTruncated() }

        let batchSize = 1_024
        var start = 0
        while start < tokens.count {
            if cancelled.get { throw CancellationError() }
            let end = min(start + batchSize, tokens.count)
            var slice = Array(tokens[start..<end])
            let status = slice.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
            }
            guard status == 0 else { throw ProviderError(.localLLM, .serviceError) }
            start = end
        }

        guard let sampler = Self.sampler(vocab: vocab, grammar: grammar) else {
            throw ProviderError(.localLLM, .malformedResponse)
        }
        defer { llama_sampler_free(sampler) }

        var output: [UInt8] = []
        var position = tokens.count
        while true {
            if cancelled.get { throw CancellationError() }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            output += Self.piece(token, vocab: vocab)
            position += 1
            if position >= capacity { throw OutputTruncated() }
            let status = llama_decode(context, llama_batch_get_one(&token, 1))
            guard status == 0 else { throw ProviderError(.localLLM, .serviceError) }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Grammar first so every later stage only ever sees tokens that keep the JSON valid. A low
    /// temperature with a fixed seed stays close to greedy while avoiding its repetition loops.
    private static func sampler(vocab: OpaquePointer?, grammar: String) -> UnsafeMutablePointer<llama_sampler>? {
        guard let constrained = llama_sampler_init_grammar(vocab, grammar, "root") else { return nil }
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(chain, constrained)
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.2))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(42))
        return chain
    }

    private func tokenize(_ text: String, vocab: OpaquePointer?) throws -> [llama_token] {
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 8)
        var count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), true, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), true, true)
        }
        guard count >= 0 else { throw ProviderError(.localLLM, .meetingTooLong) }
        return Array(tokens.prefix(Int(count)))
    }

    private static func piece(_ token: llama_token, vocab: OpaquePointer?) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(count, 0))).map { UInt8(bitPattern: $0) }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var get: Bool { lock.withLock { value } }
    func set(_ new: Bool) { lock.withLock { value = new } }
}
