import Foundation
import MM2TCore

actor DigestCheckpointStore {
    struct Checkpoint: Sendable {
        let transcript: LLMTranscript
        let digests: [PersonDigest]
        let normalization: CleanedCheckpointStore.Reference?

        func canExtend(to current: LLMTranscript) -> Bool {
            let previous = transcript.utterances
            return !previous.isEmpty && previous.count <= current.utterances.count
                && current.utterances.prefix(previous.count).elementsEqual(previous)
                && transcript.glossary == current.glossary
                && LLMPrompts.isEnglish(previous) == LLMPrompts.isEnglish(current.utterances)
        }
    }

    struct Ticket: Sendable {
        let revision: UInt64
        let previous: Checkpoint?
    }

    private var revision: UInt64 = 0
    private var acceptedRevision: UInt64 = 0
    private var latest: Checkpoint?

    func begin() -> Ticket {
        revision &+= 1
        return Ticket(revision: revision, previous: latest)
    }

    func accept(_ digests: [PersonDigest], for transcript: LLMTranscript,
                normalization: CleanedCheckpointStore.Reference? = nil, ticket: Ticket) {
        guard ticket.revision >= acceptedRevision,
              transcript.utterances.count >= (latest?.transcript.utterances.count ?? 0)
        else { return }
        latest = Checkpoint(transcript: transcript, digests: digests, normalization: normalization)
        acceptedRevision = ticket.revision
    }
}

struct DigestDelta: Decodable, Sendable {
    struct Point: Decodable, Sendable {
        let text: String
        let sources: [String]
    }

    struct Change: Decodable, Sendable {
        struct Replacement: Decodable, Sendable {
            let index: Int
            let item: Point
        }
        let speaker: String
        let remove: [Int]
        let replace: [Replacement]
        let append: [Point]
    }

    let changes: [Change]

    func applying(to previous: [PersonDigest], transcript: LLMTranscript, service: Service) throws -> [PersonDigest] {
        let malformed = ProviderError(service, .malformedResponse)
        let ids = Set(transcript.utterances.map(\.id))
        var seenSpeakers = Set<SpeakerID>()
        let speakers = transcript.utterances.map(\.speaker).filter { seenSpeakers.insert($0).inserted }
        var points: [SpeakerID: [SourcedText]] = [:]
        for digest in previous {
            guard seenSpeakers.contains(digest.speaker), points[digest.speaker] == nil else { throw malformed }
            points[digest.speaker] = digest.points
        }
        var changedSpeakers = Set<SpeakerID>()
        for change in changes {
            let speaker = SpeakerID(change.speaker)
            guard seenSpeakers.contains(speaker), changedSpeakers.insert(speaker).inserted else { throw malformed }
            let original = points[speaker] ?? []
            let indices = change.remove + change.replace.map(\.index)
            guard Set(indices).count == indices.count, indices.allSatisfy(original.indices.contains) else { throw malformed }
            func point(_ value: Point) throws -> SourcedText {
                let text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let sources = value.sources.map(UtteranceID.init)
                guard !text.isEmpty, !sources.isEmpty, Set(sources).count == sources.count,
                      sources.allSatisfy(ids.contains) else { throw malformed }
                return SourcedText(text: LLMTasks.withoutOwnName(text, of: speaker), sources: sources)
            }
            var replacements: [Int: SourcedText] = [:]
            for replacement in change.replace { replacements[replacement.index] = try point(replacement.item) }
            let removed = Set(change.remove)
            let retained = original.enumerated().compactMap { index, value in
                removed.contains(index) ? nil : replacements[index] ?? value
            }
            let appended = try change.append.map(point)
            guard Set(appended).count == appended.count, appended.allSatisfy({ !retained.contains($0) }) else { throw malformed }
            points[speaker] = retained + appended
        }
        return speakers.compactMap { speaker in
            points[speaker].map { PersonDigest(speaker: speaker, points: $0) }
        }
    }
}
