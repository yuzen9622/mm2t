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
    private let responseCache: StructuredResponseCache?
    private let summaryUpdates: SummaryCheckpointStore?
    private let digestUpdates: DigestCheckpointStore?
    private let cleanedCheckpoints: CleanedCheckpointStore?
    private let normalizationSnapshot: CleanedCheckpointStore.Snapshot?

    package init(_ generator: any StructuredGenerator, cleanChunkCharacters: Int, maxInputCharacters: Int, cleanConcurrency: Int = 1) {
        self.init(generator, cleanChunkCharacters: cleanChunkCharacters, maxInputCharacters: maxInputCharacters,
                  cleanConcurrency: cleanConcurrency, responseCache: nil)
    }

    init(_ generator: any StructuredGenerator, cleanChunkCharacters: Int, maxInputCharacters: Int,
         cleanConcurrency: Int, responseCache: StructuredResponseCache?, summaryUpdates: SummaryCheckpointStore? = nil,
         digestUpdates: DigestCheckpointStore? = nil, cleanedCheckpoints: CleanedCheckpointStore? = nil,
         normalizationSnapshot: CleanedCheckpointStore.Snapshot? = nil) {
        precondition(cleanConcurrency >= 1)
        self.cleanConcurrency = cleanConcurrency
        self.generator = generator
        self.cleanChunkCharacters = cleanChunkCharacters
        self.maxInputCharacters = maxInputCharacters
        self.responseCache = responseCache
        self.summaryUpdates = summaryUpdates
        self.digestUpdates = digestUpdates
        self.cleanedCheckpoints = cleanedCheckpoints
        self.normalizationSnapshot = normalizationSnapshot
    }

    private var service: Service { generator.service }

    private func normalizationReference(for transcript: LLMTranscript) async -> CleanedCheckpointStore.Reference? {
        if let normalizationSnapshot { return normalizationSnapshot.reference(for: transcript) }
        return await cleanedCheckpoints?.reference(for: transcript)
    }

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
        let revision = await cleanedCheckpoints?.begin()
        let chunks = Self.chunks(transcript.utterances, maxCharacters: cleanChunkCharacters)
        var offset = 0
        let offsets = chunks.map { chunk in
            defer { offset += chunk.count }
            return offset
        }
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
                // Keep the preceding six utterances even when they span several short chunks.
                let end = offsets[index]
                let context = Array(transcript.utterances[max(0, end - Self.contextUtterances)..<end])
                group.addTask { (index, try await clean(chunks[index], context: context, glossary: glossary, system: system)) }
            }
            for _ in 0..<cleanConcurrency { add() }
            while let (index, paragraphs) = try await group.next() {
                cleaned[index] = paragraphs
                add()
            }
        }
        let result = CleanedTranscript(paragraphs: cleaned.flatMap { $0 })
        try Task.checkCancellation()
        if let cleanedCheckpoints, let revision {
            await cleanedCheckpoints.accept(result, for: transcript, revision: revision)
        }
        return result
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
                schema: LLMPrompts.cleanSchema(speakers), validate: { output in
                    for paragraph in output.paragraphs where !paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = try known(paragraph.speaker, in: speakers)
                    }
                })
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
        guard let digestUpdates, !transcript.utterances.isEmpty else { return try await fullDigests(transcript) }
        try checkLength(transcript.utterances)
        let ticket = await digestUpdates.begin()
        let normalization = await normalizationReference(for: transcript)
        if let previous = ticket.previous, previous.transcript == transcript, previous.normalization == normalization {
            await digestUpdates.accept(previous.digests, for: transcript, normalization: normalization, ticket: ticket)
            return previous.digests
        }
        let digests: [PersonDigest]
        if let previous = ticket.previous, previous.canExtend(to: transcript) {
            do {
                let delta = try await whole(
                    DigestDelta.self,
                    system: LLMPrompts.system(LLMPrompts.digestPerPerson + "\n\n" + LLMPrompts.digestUpdate, for: transcript.utterances),
                    input: LLMPrompts.digestUpdateRequest(transcript, previous: previous, normalization: normalization),
                    schema: LLMPrompts.digestUpdateSchema(Self.speakers(in: transcript.utterances)),
                    validate: { delta in _ = try delta.applying(to: previous.digests, transcript: transcript, service: service) })
                digests = try delta.applying(to: previous.digests, transcript: transcript, service: service)
            } catch let error as ProviderError where error.kind == .malformedResponse {
                digests = try await fullDigests(transcript, normalization: normalization)
            }
        } else {
            digests = try await fullDigests(transcript, normalization: normalization)
        }
        await digestUpdates.accept(digests, for: transcript, normalization: normalization, ticket: ticket)
        return digests
    }

    private func fullDigests(_ transcript: LLMTranscript, normalization: CleanedCheckpointStore.Reference? = nil) async throws -> [PersonDigest] {
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
            input: LLMPrompts.digestRequest(transcript, normalization: normalization),
            schema: LLMPrompts.digestSchema(speakers), validate: { output in
                for digest in output.digests { _ = try known(digest.speaker, in: speakers) }
            })
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

    package func rewrite(_ text: String, instruction: String) async throws -> String {
        struct Output: Decodable { let text: String }
        let json = try await generator.generate(
            system: LLMPrompts.rewrite, input: LLMPrompts.rewriteRequest(text, instruction: instruction),
            schema: LLMPrompts.rewriteSchema)
        guard let output = try? JSONDecoder().decode(Output.self, from: Data(json.utf8)),
              !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ProviderError(service, .malformedResponse) }
        return output.text
    }

    package func vocabularyCorrections(from old: String, to new: String) async throws -> [VocabularyCorrection] {
        guard old != new, !old.isEmpty, !new.isEmpty else { return [] }
        guard old.count + new.count <= maxInputCharacters else { throw ProviderError(service, .meetingTooLong) }
        struct Output: Decodable {
            struct Pair: Decodable {
                enum Category: String, Decodable { case name, product, technical }
                let incorrect: String
                let correct: String
                let category: Category
            }
            let corrections: [Pair]
        }
        let output = try await whole(Output.self, system: LLMPrompts.vocabularyCorrections,
            input: "修改前：\n\(old)\n\n修改後：\n\(new)", schema: LLMPrompts.vocabularySchema)
        return VocabularyLearning.validated(output.corrections.map {
            VocabularyCorrection(incorrect: $0.incorrect, correct: $0.correct)
        }, from: old, to: new)
    }

    package func summarize(_ request: SummaryRequest) async throws -> Summary {
        guard let summaryUpdates, !request.transcript.utterances.isEmpty else { return try await fullSummary(request) }
        try checkLength(request.transcript.utterances + request.prioritized)
        let ticket = await summaryUpdates.begin()
        let normalization = await normalizationReference(for: request.transcript)
        if let previous = ticket.previous, previous.request == request, previous.normalization == normalization {
            await summaryUpdates.accept(previous.summary, for: request, normalization: normalization, ticket: ticket)
            return previous.summary
        }
        let summary: Summary
        if let previous = ticket.previous, previous.canExtend(to: request) {
            do {
                let delta = try await whole(
                    SummaryDelta.self,
                    system: LLMPrompts.system(LLMPrompts.summarize + "\n\n" + LLMPrompts.summaryUpdate,
                                              for: request.transcript.utterances),
                    input: LLMPrompts.summaryUpdateRequest(request, previous: previous, normalization: normalization),
                    schema: LLMPrompts.summaryUpdateSchema,
                    validate: { delta in _ = try delta.applying(to: previous.summary, request: request, service: service) })
                summary = try delta.applying(to: previous.summary, request: request, service: service)
            } catch let error as ProviderError where error.kind == .malformedResponse {
                // Invalid edits cannot silently preserve an obsolete action or deadline.
                summary = try await fullSummary(request, normalization: normalization)
            }
        } else {
            summary = try await fullSummary(request, normalization: normalization)
        }
        await summaryUpdates.accept(summary, for: request, normalization: normalization, ticket: ticket)
        return summary
    }

    private func fullSummary(_ request: SummaryRequest, normalization: CleanedCheckpointStore.Reference? = nil) async throws -> Summary {
        let utterances = request.transcript.utterances
        guard !utterances.isEmpty else { return Summary(decisions: [], discussionPoints: [], actionItems: []) }
        try checkLength(utterances + request.prioritized)
        struct Output: Decodable {
            struct Point: Decodable { let text: String; let sources: [String] }
            let headline: String?
            let title: String?
            let decisions: [Point]
            let discussionPoints: [Point]
            let actionItems: [SummaryDelta.Action]
        }
        let speakers = Self.speakers(in: utterances)
        let output = try await whole(
            Output.self, system: LLMPrompts.system(LLMPrompts.summarize, for: utterances),
            input: LLMPrompts.summaryRequest(request, normalization: normalization),
            schema: LLMPrompts.summarySchema(speakers), validate: { output in
                for action in output.actionItems where action.dueDate != nil {
                    guard ActionDeadline.parse(action.dueDate, timeZoneIdentifier: request.timeZoneIdentifier) != nil else {
                        throw ProviderError(service, .malformedResponse)
                    }
                }
            })
        let ids = Set(utterances.map(\.id))
        let sourced = { (points: [Output.Point]) in
            points.map { SourcedText(text: $0.text, sources: Self.sources($0.sources, within: ids)) }
        }
        let headline = output.headline?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = output.title?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "「」\"'。")))
        return Summary(
            headline: headline?.isEmpty == false ? headline : nil,
            title: title?.isEmpty == false && title?.contains("{{") == false ? title : nil,
            decisions: sourced(output.decisions),
            discussionPoints: sourced(output.discussionPoints),
            actionItems: output.actionItems.map { item in
                // An owner outside this meeting is dropped rather than failing the whole summary.
                let owner = item.owner.map(SpeakerID.init).flatMap { speakers.contains($0) ? $0 : nil }
                let due = ActionDeadline.parse(item.dueDate, timeZoneIdentifier: request.timeZoneIdentifier)
                return .init(text: item.text, owner: owner, sources: Self.sources(item.sources, within: ids), due: due)
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
    private func whole<T: Decodable>(_ type: T.Type, system: String, input: String, schema: JSON,
                                     validate: (@Sendable (T) throws -> Void)? = nil) async throws -> T {
        do {
            return try await generate(type, system: system, input: input, schema: schema, validate: validate)
        } catch is OutputTruncated {
            throw ProviderError(service, .meetingTooLong)
        }
    }

    private func generate<T: Decodable>(_ type: T.Type, system: String, input: String, schema: JSON,
                                        validate: (@Sendable (T) throws -> Void)? = nil) async throws -> T {
        let generate: @Sendable () async throws -> String = {
            let text = try await generator.generate(system: system, input: input, schema: schema)
            guard let output = try? JSONDecoder().decode(type, from: Data(text.utf8)) else {
                throw ProviderError(service, .malformedResponse)
            }
            try validate?(output)
            return text
        }
        let text: String
        if let responseCache {
            text = try await responseCache.response(
                for: .init(system: system, input: input, schema: schema.serialized()), generate: generate)
        } else {
            text = try await generate()
        }
        return try JSONDecoder().decode(type, from: Data(text.utf8))
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
