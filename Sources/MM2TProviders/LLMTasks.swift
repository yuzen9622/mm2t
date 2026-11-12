import Foundation
import MM2TCore

/// A model that answers one prompt with JSON text matching a schema. Gemini and the on-device
/// model differ only here; prompts, chunking and checking what came back are `LLMTasks`.
package protocol StructuredGenerator: Sendable {
    var service: Service { get }
    /// Throws `OutputTruncated` when the answer hit the model's output cap, so a chunked task can retry smaller.
    func generate(system: String, input: String, schema: JSON) async throws -> String
}

package struct OutputTruncated: Error {
    package init() {}
}

/// The four LLM tasks over any `StructuredGenerator`.
package struct LLMTasks: Sendable {
    let generator: any StructuredGenerator
    /// Utterance text per cleaned-transcript request; the cleaned transcript is as long as its input.
    let cleanChunkCharacters: Int
    /// Transcript text sent whole to the other three tasks.
    let maxInputCharacters: Int
    /// Cleaned-transcript requests in flight at once. A hosted model answers several in the time of
    /// one; an on-device model has one set of weights, so it stays at 1.
    let cleanConcurrency: Int

    package init(_ generator: any StructuredGenerator, cleanChunkCharacters: Int, maxInputCharacters: Int, cleanConcurrency: Int = 1) {
        precondition(cleanConcurrency >= 1)
        self.cleanConcurrency = cleanConcurrency
        self.generator = generator
        self.cleanChunkCharacters = cleanChunkCharacters
        self.maxInputCharacters = maxInputCharacters
    }

    private var service: Service { generator.service }

    package func inferNames(_ request: NameInferenceRequest) async throws -> [NameGuess] {
        guard !request.unnamedSpeakers.isEmpty, !request.transcript.utterances.isEmpty else { return [] }
        try checkLength(request.transcript.utterances)
        struct Output: Decodable {
            struct Guess: Decodable { let speaker: String; let name: String; let reason: String }
            let guesses: [Guess]
        }
        let output = try await whole(
            Output.self, system: LLMPrompts.system(LLMPrompts.inferNames, for: request.transcript.utterances), input: LLMPrompts.nameRequest(request),
            schema: LLMPrompts.nameSchema(request.unnamedSpeakers))
        let unnamed = Set(request.unnamedSpeakers)
        return output.guesses.compactMap { guess in
            let name = guess.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let speaker = SpeakerID(guess.speaker)
            guard unnamed.contains(speaker), !name.isEmpty else { return nil }
            return NameGuess(speaker: speaker, name: name, reason: guess.reason)
        }
    }

    /// Cleans the transcript in chunks of whole utterances, because the output is as long as the input.
    /// A chunk whose output still hits the cap is split in half and retried.
    package func cleanTranscript(_ transcript: LLMTranscript) async throws -> CleanedTranscript {
        let chunks = Self.chunks(transcript.utterances, maxCharacters: cleanChunkCharacters)
        // The glossary rides along with every chunk, so a long one is capped rather than crowding out the transcript.
        let glossary = Array(transcript.glossary.prefix(200))
        // Decided once for the whole meeting: a short chunk alone could tip either way.
        let system = LLMPrompts.system(LLMPrompts.cleanTranscript, for: transcript.utterances)
        var cleaned = [[CleanedTranscript.Paragraph]](repeating: [], count: chunks.count)
        var next = 0
        try await withThrowingTaskGroup(of: (Int, [CleanedTranscript.Paragraph]).self) { group in
            func add() {
                guard next < chunks.count else { return }
                let index = next
                next += 1
                // The lines just before a chunk tell the model who was answering whom.
                let context = index == 0 ? [] : Array(chunks[index - 1].suffix(Self.contextUtterances))
                group.addTask { (index, try await clean(chunks[index], context: context, glossary: glossary, system: system)) }
            }
            for _ in 0..<cleanConcurrency { add() }
            while let (index, paragraphs) = try await group.next() {
                cleaned[index] = paragraphs
                add()
            }
        }
        return CleanedTranscript(paragraphs: cleaned.flatMap { $0 })
    }

    static let contextUtterances = 6

    private func clean(_ chunk: [LLMUtterance], context: [LLMUtterance], glossary: [String], system: String) async throws -> [CleanedTranscript.Paragraph] {
        struct Output: Decodable {
            struct Paragraph: Decodable { let speaker: String; let text: String; let sources: [String] }
            let paragraphs: [Paragraph]
        }
        let speakers = Self.speakers(in: chunk)
        do {
            let output = try await generate(
                Output.self, system: system,
                input: LLMPrompts.cleanRequest(chunk, context: context, glossary: glossary),
                schema: LLMPrompts.cleanSchema(speakers))
            let ids = Set(chunk.map(\.id))
            return try output.paragraphs.compactMap {
                let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return CleanedTranscript.Paragraph(
                    speaker: try known($0.speaker, in: speakers), text: text,
                    sources: Self.sources($0.sources, within: ids))
            }
        } catch is OutputTruncated where chunk.count > 1 {
            let half = chunk.count / 2
            let first = Array(chunk[..<half])
            return try await clean(first, context: context, glossary: glossary, system: system)
                + clean(Array(chunk[half...]), context: Array(first.suffix(Self.contextUtterances)), glossary: glossary, system: system)
        } catch is OutputTruncated {
            throw ProviderError(service, .meetingTooLong)
        }
    }

    package func digestPerPerson(_ transcript: LLMTranscript) async throws -> [PersonDigest] {
        guard !transcript.utterances.isEmpty else { return [] }
        try checkLength(transcript.utterances)
        struct Output: Decodable {
            struct Digest: Decodable { let speaker: String; let points: [Point] }
            struct Point: Decodable { let text: String; let sources: [String] }
            let digests: [Digest]
        }
        let speakers = Self.speakers(in: transcript.utterances)
        let output = try await whole(
            Output.self, system: LLMPrompts.system(LLMPrompts.digestPerPerson, for: transcript.utterances),
            input: "逐字稿：\n" + LLMPrompts.render(transcript.utterances),
            schema: LLMPrompts.digestSchema(speakers))
        let ids = Set(transcript.utterances.map(\.id))
        let digests = try output.digests.map { digest in
            let speaker = try known(digest.speaker, in: speakers)
            return PersonDigest(
                speaker: speaker,
                points: digest.points.map {
                    SourcedText(text: Self.withoutOwnName($0.text, of: speaker), sources: Self.sources($0.sources, within: ids))
                })
        }
        return digests.sorted { speakers.firstIndex(of: $0.speaker)! < speakers.firstIndex(of: $1.speaker)! }
    }

    /// A digest point sits under its speaker's heading, so a leading `{{speaker:r1}}` (the model's habit) only repeats it.
    static func withoutOwnName(_ text: String, of speaker: SpeakerID) -> String {
        let token = SpeakerMention.token(speaker)
        guard text.hasPrefix(token) else { return text }
        let rest = text.dropFirst(token.count).drop { " 　:：,，、".contains($0) }
        return rest.isEmpty ? text : String(rest)
    }

    package func summarize(_ request: SummaryRequest) async throws -> Summary {
        let utterances = request.transcript.utterances
        guard !utterances.isEmpty else { return Summary(decisions: [], discussionPoints: [], actionItems: []) }
        try checkLength(utterances + request.prioritized)
        struct Output: Decodable {
            struct Point: Decodable { let text: String; let sources: [String] }
            struct Action: Decodable { let text: String; let owner: String?; let sources: [String] }
            let headline: String?
            let title: String?
            let terms: [String]?
            let decisions: [Point]
            let discussionPoints: [Point]
            let actionItems: [Action]
        }
        let speakers = Self.speakers(in: utterances)
        let output = try await whole(
            Output.self, system: LLMPrompts.system(LLMPrompts.summarize, for: utterances), input: LLMPrompts.summaryRequest(request),
            schema: LLMPrompts.summarySchema(speakers))
        let ids = Set(utterances.map(\.id))
        let sourced = { (points: [Output.Point]) in
            points.map { SourcedText(text: $0.text, sources: Self.sources($0.sources, within: ids)) }
        }
        let headline = output.headline?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = output.title?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "「」\"'。")))
        var seenTerms = Set<String>()
        let terms = (output.terms ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 40 && !$0.contains("{{") && seenTerms.insert($0.lowercased()).inserted }
        return Summary(
            headline: headline?.isEmpty == false ? headline : nil,
            title: title?.isEmpty == false && title?.contains("{{") == false ? title : nil,
            terms: terms,
            decisions: sourced(output.decisions),
            discussionPoints: sourced(output.discussionPoints),
            actionItems: output.actionItems.map { item in
                // An owner outside this meeting is dropped rather than failing the whole summary.
                let owner = item.owner.map(SpeakerID.init).flatMap { speakers.contains($0) ? $0 : nil }
                return .init(text: item.text, owner: owner, sources: Self.sources(item.sources, within: ids))
            })
    }

    // MARK: Long meetings

    static func chunks(_ utterances: [LLMUtterance], maxCharacters: Int) -> [[LLMUtterance]] {
        var chunks: [[LLMUtterance]] = []
        var current: [LLMUtterance] = []
        var size = 0
        for utterance in utterances {
            if !current.isEmpty && size + utterance.text.count > maxCharacters {
                chunks.append(current)
                current = []
                size = 0
            }
            current.append(utterance)
            size += utterance.text.count
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func checkLength(_ utterances: [LLMUtterance]) throws {
        if utterances.reduce(0, { $0 + $1.text.count }) > maxInputCharacters {
            throw ProviderError(service, .meetingTooLong)
        }
    }

    /// A whole-transcript task has nothing smaller to retry with when its output hits the cap.
    private func whole<T: Decodable>(_ type: T.Type, system: String, input: String, schema: JSON) async throws -> T {
        do {
            return try await generate(type, system: system, input: input, schema: schema)
        } catch is OutputTruncated {
            throw ProviderError(service, .meetingTooLong)
        }
    }

    private func generate<T: Decodable>(_ type: T.Type, system: String, input: String, schema: JSON) async throws -> T {
        let text = try await generator.generate(system: system, input: input, schema: schema)
        guard let output = try? JSONDecoder().decode(T.self, from: Data(text.utf8)) else {
            throw ProviderError(service, .malformedResponse)
        }
        return output
    }

    // MARK: Validation of model output

    private static func speakers(in utterances: [LLMUtterance]) -> [SpeakerID] {
        var order: [SpeakerID] = []
        for u in utterances where !order.contains(u.speaker) { order.append(u.speaker) }
        return order
    }

    private func known(_ raw: String, in speakers: [SpeakerID]) throws -> SpeakerID {
        let id = SpeakerID(raw.trimmingCharacters(in: CharacterSet(charactersIn: "{} ")).replacingOccurrences(of: "speaker:", with: ""))
        guard speakers.contains(id) else { throw ProviderError(service, .malformedResponse) }
        return id
    }

    /// Ids the model invented are dropped; the rest keep transcript order without duplicates.
    private static func sources(_ raw: [String], within ids: Set<UtteranceID>) -> [UtteranceID] {
        var seen = Set<UtteranceID>()
        return raw.map(UtteranceID.init).filter { ids.contains($0) && seen.insert($0).inserted }
    }
}
