import Foundation
import MM2TCore

/// A recording's latest accepted summary. Revisions prevent an older, slower request from
/// replacing a newer checkpoint; retaining one checkpoint bounds this state independently of memoization.
actor SummaryCheckpointStore {
    struct Checkpoint: Sendable {
        let request: SummaryRequest
        let summary: Summary
        let normalization: CleanedCheckpointStore.Reference?

        func canExtend(to current: SummaryRequest) -> Bool {
            let previous = request.transcript.utterances
            let utterances = current.transcript.utterances
            guard !previous.isEmpty, previous.count <= utterances.count,
                  utterances.prefix(previous.count).elementsEqual(previous),
                  request.transcript.glossary == current.transcript.glossary,
                  request.meetingStartedAt == current.meetingStartedAt,
                  request.timeZoneIdentifier == current.timeZoneIdentifier,
                  LLMPrompts.isEnglish(previous) == LLMPrompts.isEnglish(utterances)
            else { return false }
            let priorIDs = Set(previous.map(\.id))
            return current.prioritized.filter { priorIDs.contains($0.id) } == request.prioritized
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

    func accept(_ summary: Summary, for request: SummaryRequest, normalization: CleanedCheckpointStore.Reference? = nil, ticket: Ticket) {
        guard ticket.revision >= acceptedRevision,
              request.transcript.utterances.count >= (latest?.request.transcript.utterances.count ?? 0)
        else { return }
        latest = Checkpoint(request: request, summary: summary, normalization: normalization)
        acceptedRevision = ticket.revision
    }
}

struct SummaryDelta: Decodable, Sendable {
    struct Point: Decodable, Sendable {
        let text: String
        let sources: [String]
    }

    struct Action: Decodable, Sendable {
        let text: String
        let owner: String?
        let sources: [String]
        let dueDate: String?

        private enum CodingKeys: CodingKey { case text, owner, sources, dueDate }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            text = try values.decode(String.self, forKey: .text)
            owner = try values.decodeIfPresent(String.self, forKey: .owner)
            sources = try values.decode([String].self, forKey: .sources)
            dueDate = try values.decode(String?.self, forKey: .dueDate)
        }
    }

    struct Changes<Item: Decodable & Sendable>: Decodable, Sendable {
        struct Replacement: Decodable, Sendable {
            let index: Int
            let item: Item
        }
        let remove: [Int]
        let replace: [Replacement]
        let append: [Item]

        func applying<Value>(to original: [Value], malformed: ProviderError,
                             convert: (Item) throws -> Value) throws -> [Value] {
            let indices = remove + replace.map(\.index)
            guard Set(indices).count == indices.count, indices.allSatisfy(original.indices.contains) else { throw malformed }
            let removed = Set(remove)
            var replacements: [Int: Value] = [:]
            for replacement in replace { replacements[replacement.index] = try convert(replacement.item) }
            return original.enumerated().compactMap { index, value in
                removed.contains(index) ? nil : replacements[index] ?? value
            } + (try append.map(convert))
        }
    }

    let headline: String?
    let title: String?
    let decisions: Changes<Point>
    let discussionPoints: Changes<Point>
    let actionItems: Changes<Action>

    func applying(to previous: Summary, request: SummaryRequest, service: Service) throws -> Summary {
        let malformed = ProviderError(service, .malformedResponse)
        let ids = Set(request.transcript.utterances.map(\.id))
        let speakers = Set(request.transcript.utterances.map(\.speaker))
        func sources(_ raw: [String]) throws -> [UtteranceID] {
            let sources = raw.map(UtteranceID.init)
            guard !sources.isEmpty, Set(sources).count == sources.count,
                  sources.allSatisfy(ids.contains) else { throw malformed }
            return sources
        }
        func text(_ raw: String) throws -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw malformed }
            return trimmed
        }
        func point(_ value: Point) throws -> SourcedText {
            try SourcedText(text: text(value.text), sources: sources(value.sources))
        }
        let headline = headline.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let title = title.map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "「」\"'。"))) }
        if let title, title.contains("{{") { throw malformed }
        return try Summary(
            headline: headline.map { $0.isEmpty ? nil : $0 } ?? previous.headline,
            title: title.map { $0.isEmpty ? nil : $0 } ?? previous.title,
            terms: previous.terms,
            decisions: decisions.applying(to: previous.decisions, malformed: malformed, convert: point),
            discussionPoints: discussionPoints.applying(to: previous.discussionPoints, malformed: malformed, convert: point),
            actionItems: actionItems.applying(to: previous.actionItems, malformed: malformed) { action in
                let owner = action.owner.map(SpeakerID.init)
                guard owner.map(speakers.contains) ?? true else { throw malformed }
                let parsed = ActionDeadline.parse(action.dueDate, timeZoneIdentifier: request.timeZoneIdentifier)
                if action.dueDate != nil, parsed == nil { throw malformed }
                return try Summary.ActionItem(text: text(action.text), owner: owner, sources: sources(action.sources), due: parsed)
            })
    }
}
