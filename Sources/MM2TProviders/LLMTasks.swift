import Foundation
import MM2TCore
import NaturalLanguage

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
            Output.self, system: LLMPrompts.nameSystem(for: request.transcript.utterances), input: LLMPrompts.nameRequest(request),
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
        let system = LLMPrompts.cleanSystem
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
        let reviewed = try await reviewReadability(cleaned.flatMap { $0 }, transcript: transcript)
        let result = CleanedTranscript(paragraphs: reviewed)
        try Task.checkCancellation()
        if let cleanedCheckpoints, let revision {
            await cleanedCheckpoints.accept(result, for: transcript, revision: revision)
        }
        return result
    }

    /// Overlapping tracks may contain an independent aside or a garbled rendition of the
    /// other track. Edit each cited line individually so a fluent neighbour cannot replace it.
    private func reviewReadability(_ paragraphs: [CleanedTranscript.Paragraph], transcript: LLMTranscript) async throws -> [CleanedTranscript.Paragraph] {
        struct Edit: Decodable { let text: String }
        let lines = transcript.utterances
        let indices = Dictionary(lines.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [CleanedTranscript.Paragraph] = []
        for var paragraph in paragraphs {
            let sources = paragraph.sources.compactMap { indices[$0] }
            let needsReview = sources.contains { index in
                let line = lines[index]
                guard line.text.range(of: #"\p{Han}"#, options: .regularExpression) != nil else { return false }
                return lines[max(0, index - Self.contextUtterances)..<min(lines.count, index + Self.contextUtterances + 1)].contains {
                    $0.speaker != line.speaker && $0.range.start < line.range.end && line.range.start < $0.range.end
                        && NLLanguageRecognizer.dominantLanguage(for: $0.text) == .english
                }
            }
            guard needsReview else {
                guard let first = sources.min(), let last = sources.max() else {
                    result.append(paragraph)
                    continue
                }
                let before = lines[max(0, first - Self.contextUtterances)..<first]
                let after = lines[(last + 1)..<min(lines.count, last + 1 + Self.contextUtterances)]
                let neighbours = Array(before + after)
                if let ending = paragraph.text.range(of: Self.hesitantTail, options: .regularExpression) {
                    // Restrict the model to classifying the tail; it cannot change the preceding date or assertion.
                    let tail = String(paragraph.text[ending].dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                    if try await unclearEnding(tail, in: paragraph.text, neighbours: neighbours) {
                        let prefix = paragraph.text[...ending.lowerBound]
                        paragraph = .init(speaker: paragraph.speaker, text: String(prefix) + "〔辨識不清〕", sources: paragraph.sources)
                    }
                }
                // 筆速 is meaningful for handwriting. Only resolve the homophone when the conversation
                // explicitly measures a data retrieval operation in records and time.
                let cited = sources.map { lines[$0] }
                let evidence = (Array(before) + cited + Array(after)).map(\.text).joined(separator: " ")
                if paragraph.text.contains("筆速"),
                   evidence.range(of: #"檢索|爬蟲|爬的|抓資料|抓下來|資料庫查詢"#, options: .regularExpression) != nil,
                   evidence.range(of: #"[數幾百千萬一二三四五六七八九十0-9]\s*筆"#, options: .regularExpression) != nil,
                   evidence.range(of: #"分鐘|小時|秒"#, options: .regularExpression) != nil {
                    paragraph = .init(speaker: paragraph.speaker, text: paragraph.text.replacingOccurrences(of: "筆速", with: "筆數"), sources: paragraph.sources)
                }
                if let issue = Self.readabilityIssue(paragraph.text) {
                    let original = paragraph.text
                    let input = LLMPrompts.readabilityRequest(original, context: neighbours,
                                                              glossary: Array(transcript.glossary.prefix(200)), issue: issue, evidence: cited)
                    do {
                        let edit = try await generate(Edit.self, system: LLMPrompts.cleanSystem, input: input,
                                                      schema: .object([("text", .string)]))
                        let text = edit.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty, !text.contains("{{speaker:"), Self.keepsMixedLanguage(source: original, output: text),
                           !(original.contains("筆數") && text.contains("筆速")),
                           !Self.changedLanguage(source: original, output: text),
                           !Self.lostShortPhrase(in: cited, output: text, reviewingDraft: true) {
                            result.append(.init(speaker: paragraph.speaker, text: text, sources: paragraph.sources))
                            continue
                        }
                    } catch let error as ProviderError where error.kind == .malformedResponse { }
                }
                result.append(paragraph)
                continue
            }
            var edits: [CleanedTranscript.Paragraph] = []
            for index in sources {
                let line = lines[index]
                let context = Array(lines[max(0, index - Self.contextUtterances)..<index])
                let original = Self.removingOrphanedEnding(line.text)
                let input = LLMPrompts.readabilityRequest(original, context: context, glossary: Array(transcript.glossary.prefix(200)))
                do {
                    let edit = try await generate(Edit.self, system: LLMPrompts.cleanSystem, input: input,
                                                  schema: .object([("text", .string)]))
                    let text = original == line.text ? edit.text.trimmingCharacters(in: .whitespacesAndNewlines) : Self.removingOrphanedEnding(edit.text)
                    guard !text.isEmpty, !text.contains("{{speaker:"),
                          Self.keepsMixedLanguage(source: original, output: text),
                          !Self.changedLanguage(source: line.text, output: text),
                          !Self.lostShortPhrase(in: [line], output: text) else { break }
                    edits.append(.init(speaker: line.speaker, text: text, sources: [line.id]))
                } catch let error as ProviderError where error.kind == .malformedResponse { break }
            }
            if edits.count == sources.count {
                result += edits
            } else {
                var text = paragraph.text
                if let last = sources.last, Self.removingOrphanedEnding(lines[last].text) != lines[last].text {
                    text = Self.removingOrphanedEnding(text)
                }
                result.append(.init(speaker: paragraph.speaker, text: text, sources: paragraph.sources))
            }
        }
        return result
    }

    private func unclearEnding(_ tail: String, in sentence: String, neighbours: [LLMUtterance]) async throws -> Bool {
        struct Decision: Decodable { let status: String }
        let input = LLMPrompts.endingRequest(tail, sentence: sentence, context: neighbours)
        do {
            let decision = try await generate(Decision.self, system: LLMPrompts.cleanSystem, input: input,
                                              schema: .object([("status", .dict([("type", .text("string")), ("enum", .list([.text("meaningful"), .text("unclear")]))]))]))
            return decision.status == "unclear"
        } catch let error as ProviderError where error.kind == .malformedResponse {
            return false
        }
    }

    // These cues nominate a paragraph for review. They never replace the speaker’s words.
    private static let hesitantTail = #"[。！？]\s*[哦喔呃欸哎]\p{Han}{1,4}[。！]?\s*$"#
    private static func readabilityIssue(_ text: String) -> String? {
        let cues = [
            (#"([一二三四五六七八九十百千\d]+)\s*[，,]\s*(?:最少|至少|大概|大約|應該|差不多).{0,5}\1"#, "核對同一數量是否說到一半重新起頭，只留下最後說完整的數量、單位和限定詞。依前後文校正量測項目的同音詞。"),
            (#"(?:看|取決於).{0,5}[量速數率].{0,32}(?:分鐘|小時|秒|\d+\s*筆)"#, "這段在回答耗時。找出問句在問哪個動作、回答用哪個量詞計數，再核對決定耗時的是數量還是某種速度。例：若討論從系統抓資料，並用幾筆來說明耗時，這裡的量是資料筆數。保留疑問、實測數量與約略的時間。"),
            (#"(不是|不對)[，,]?\1[，,]|([才就十])\2.{0,12}[筆人分鐘]"#, "將同一位講者中斷重來的語句寫成完整句。自我更正時只留最後採用的說法與更正語氣。")
        ]
        return cues.first { text.range(of: $0.0, options: .regularExpression) != nil }?.1
    }

    /// ASR occasionally appends the first word of the next sentence to a finished one.
    private static func removingOrphanedEnding(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)([。！？.!?])\s*(in|at|of|to|and|the)\s*$"#,
                                  with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func keepsMixedLanguage(source: String, output: String) -> Bool {
        let terms = source.lowercased().split { !$0.isASCII || !$0.isLetter }.filter { $0.count >= 3 }
        return terms.isEmpty || terms.contains { output.lowercased().contains($0) }
    }

    static let contextUtterances = 6

    private func clean(_ chunk: [LLMUtterance], context: [LLMUtterance], glossary: [String], system: String, allowLanguageRetry: Bool = true) async throws -> [CleanedTranscript.Paragraph] {
        struct Output: Decodable {
            struct Paragraph: Decodable { let speaker: String; let text: String; let sources: [String] }
            let paragraphs: [Paragraph]
        }
        guard chunk.contains(where: { Self.hasContent($0.text) }) else { return [] }
        let speakers = Self.speakers(in: chunk)
        do {
            let output = try await generate(
                Output.self, system: system,
                input: LLMPrompts.cleanRequest(chunk, context: context, glossary: glossary, repairing: !allowLanguageRetry),
                schema: LLMPrompts.cleanSchema(speakers, sources: chunk.map(\.id)), validate: { output in
                    for paragraph in output.paragraphs where !paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = try known(paragraph.speaker, in: speakers)
                    }
                })
            let ids = Set(chunk.map(\.id))
            let paragraphs: [CleanedTranscript.Paragraph] = try output.paragraphs.compactMap {
                let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return CleanedTranscript.Paragraph(
                    speaker: try known($0.speaker, in: speakers), text: text,
                    sources: Self.sources($0.sources, within: ids))
            }
            let citedIDs = Set(paragraphs.flatMap(\.sources))
            let missing = chunk.filter { !citedIDs.contains($0.id) && Self.hasContent($0.text) }
            if paragraphs.isEmpty { return Self.originalParagraphs(missing) }
            let speakerByID = Dictionary(chunk.map { ($0.id, $0.speaker) }, uniquingKeysWith: { first, _ in first })
            let invalidAttribution = paragraphs.contains { paragraph in
                paragraph.sources.isEmpty || paragraph.sources.contains { speakerByID[$0] != paragraph.speaker }
            }
            if invalidAttribution || !missing.isEmpty {
                guard allowLanguageRetry else { return Self.originalParagraphs(chunk) }
                // With unreliable citations the output cannot be matched to individual inputs.
                // Rebuild consecutive turns separately so a speaker's aside cannot disappear in a merge.
                var rebuilt: [CleanedTranscript.Paragraph] = []
                var preceding = context
                var rest = chunk[...]
                while let first = rest.first {
                    let turn = rest.prefix { $0.speaker == first.speaker }
                    rebuilt += try await repair(Array(turn), context: Array(preceding.suffix(Self.contextUtterances)), glossary: glossary, system: system)
                    preceding.append(contentsOf: turn)
                    rest = rest.dropFirst(turn.count)
                }
                return rebuilt
            }
            var checked: [CleanedTranscript.Paragraph] = []
            for paragraph in paragraphs {
                let cited = Set(paragraph.sources)
                let source = chunk.filter { cited.contains($0.id) }
                if !source.contains(where: { Self.hasContent($0.text) }) { continue }
                if Self.lostShortPhrase(in: source, output: paragraph.text) || Self.changedLanguage(source: source.map(\.text).joined(separator: " "), output: paragraph.text) {
                    checked += allowLanguageRetry
                        ? try await repair(source, context: Array((context + chunk.prefix { $0.id != source.first?.id }).suffix(Self.contextUtterances)), glossary: glossary, system: system)
                        : Self.originalParagraphs(source)
                } else {
                    checked.append(paragraph)
                }
            }
            return checked
        } catch is OutputTruncated where chunk.count > 1 {
            let half = chunk.count / 2
            let first = Array(chunk[..<half])
            return try await clean(first, context: context, glossary: glossary, system: system, allowLanguageRetry: allowLanguageRetry)
                + clean(Array(chunk[half...]), context: Array(first.suffix(Self.contextUtterances)), glossary: glossary, system: system, allowLanguageRetry: allowLanguageRetry)
        } catch is OutputTruncated {
            throw ProviderError(service, .meetingTooLong)
        }
    }

    private static func originalParagraphs(_ source: [LLMUtterance]) -> [CleanedTranscript.Paragraph] {
        source.filter { hasContent($0.text) }.map {
            .init(speaker: $0.speaker, text: $0.text, sources: [$0.id])
        }
    }

    private func repair(_ source: [LLMUtterance], context: [LLMUtterance], glossary: [String], system: String) async throws -> [CleanedTranscript.Paragraph] {
        do {
            let result = try await clean(source, context: context, glossary: glossary, system: system, allowLanguageRetry: false)
            let required = source.filter { Self.hasContent($0.text) }.map(\.id)
            let requiredIDs = Set(required)
            if result.flatMap(\.sources).filter(requiredIDs.contains) == required { return result }
        } catch let error as ProviderError where error.kind == .malformedResponse || error.kind == .meetingTooLong {
            // A malformed repair still has a lossless local fallback.
        }
        return Self.originalParagraphs(source)
    }

    private static let fillers: Set<String> = ["嗯", "呃", "嗯嗯", "uh", "um", "えー", "ええと"]

    private static func hasContent(_ text: String) -> Bool {
        let words = text.lowercased().filter { $0.isLetter || $0.isNumber }
        if text.contains("?") || text.contains("？") { return !words.isEmpty }
        return !words.isEmpty && !fillers.contains(words)
    }

    /// Short statements often consist entirely of their key word. Preserve it when a model
    /// combines several greetings, questions or status updates under one citation list.
    private static func lostShortPhrase(in source: [LLMUtterance], output: String, reviewingDraft: Bool = false) -> Bool {
        let normalized = output.lowercased().filter { $0.isLetter || $0.isNumber }
        let boundaries = CharacterSet(charactersIn: "。！？!?")
        for utterance in source {
            for phrase in utterance.text.components(separatedBy: boundaries) where hasContent(phrase) {
                let key = phrase.lowercased().filter { $0.isLetter || $0.isNumber }
                if key == "うん", phrase != utterance.text, utterance.text.hasPrefix("うん。") { continue }
                // A trailing preposition after a completed sentence is a common ASR fragment.
                if utterance.text.hasSuffix(phrase), phrase != utterance.text, ["in", "at", "of", "to", "and", "the"].contains(key) { continue }
                if reviewingDraft, key == "好", utterance.text.hasSuffix("。好。"),
                   utterance.text.count > 12 { continue }
                if key.count <= 5 && !normalized.contains(key) { return true }
            }
        }
        return false
    }

    /// Only flag a clear English/Chinese switch. Short or code-switched sources are ambiguous.
    static func changedLanguage(source: String, output: String) -> Bool {
        func hasHan(_ text: String) -> Bool { text.range(of: #"\p{Han}"#, options: .regularExpression) != nil }
        func isChinese(_ text: String) -> Bool {
            let language = NLLanguageRecognizer.dominantLanguage(for: text)
            return language == .traditionalChinese || language == .simplifiedChinese
        }
        let kana = #"\p{Hiragana}|\p{Katakana}"#
        if source.range(of: kana, options: .regularExpression) != nil,
           output.range(of: kana, options: .regularExpression) == nil { return true }
        guard source.filter(\.isLetter).count >= 16, output.filter(\.isLetter).count >= 8 else { return false }
        if !hasHan(source), hasHan(output) {
            return NLLanguageRecognizer.dominantLanguage(for: source) == .english && isChinese(output)
        }
        if hasHan(source), !hasHan(output), source.range(of: #"\p{Latin}"#, options: .regularExpression) == nil {
            return isChinese(source) && NLLanguageRecognizer.dominantLanguage(for: output) == .english
        }
        return false
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
                    system: LLMPrompts.system(LLMPrompts.digestPerPerson + "\n\n" + LLMPrompts.digestUpdate, language: transcript.outputLanguage),
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
            Output.self, system: LLMPrompts.system(LLMPrompts.digestPerPerson, language: transcript.outputLanguage),
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
                                              language: request.transcript.outputLanguage),
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
            Output.self, system: LLMPrompts.system(LLMPrompts.summarize, language: request.transcript.outputLanguage),
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
