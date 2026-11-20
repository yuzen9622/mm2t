import Foundation
import MM2TCore
import MM2TProviders

public struct FolderProposal: Codable, Sendable {
    public var name: String
    public var meetings: [MeetingID]
    var revisions: [MeetingID: UUID]
}

struct FilingResult: Sendable {
    var batch: UUID?
    var moved: Int
    var proposals: [FolderProposal]
}

@MainActor enum FolderOrganizer {
    static func run(_ folders: MeetingFolders, library: MeetingLibrary, provider: any LLMProvider, question: String, scope: Set<MeetingID>?, automatic: Bool, explicitReferences: Set<MeetingID> = []) async throws -> FilingResult {
        if !automatic {
            let action = try await AssistantGeneration.userDirective(provider: provider, question: question,
                rule: "write ONLY if asked to move, file, or classify meeting records into folders, including a request to organize unfiled meetings. Advice, summaries, organizing discussion points or read-only questions mean none.", choices: ["write", "none"])
            guard action == "write" else { throw AssistantQueryError.invalid("No current request to file meetings") }
        }
        let meetings = try await library.list()
        let options = folders.folders.map { folder in
            let examples = meetings.filter { folders.folder(of: $0.id) == folder.id && folders.isManuallyFiled($0.id) }.prefix(3)
            return ["id": folder.id.uuidString, "name": folder.name, "examples": examples.map { description($0) }.joined(separator: "\n")]
        }
        // Only an exact, unambiguous title explicitly named as the object of a move is a target.
        var named: MeetingID?
        if !automatic, explicitReferences.isEmpty {
            let mentioned = meetings.filter { meeting in
                let title = meeting.metadata.title
                guard !title.isEmpty else { return false }
                return ["「\(title)」", "『\(title)』", "\"\(title)\"", "把\(title)移", "將\(title)移", "move \(title) to"].contains { question.localizedCaseInsensitiveContains($0) }
            }
            if !mentioned.isEmpty {
                let titles = Array(Set(mentioned.map { $0.metadata.title })).sorted()
                let value = try await AssistantGeneration.userDirective(provider: provider, question: question,
                    rule: "Return the exact meeting title ONLY if the user explicitly identifies that single meeting as the object of a move. Generic words like 會議 in 整理未分類會議 are never a named record. Otherwise return the empty string.", choices: [""] + titles)
                let matches = mentioned.filter { $0.metadata.title == value }
                if matches.count == 1 { named = matches[0].id }
            }
        }
        let candidates = meetings.filter { meeting in
            if let named { return meeting.id == named }
            if let scope, !scope.contains(meeting.id) { return false }
            return folders.folder(of: meeting.id) == nil || explicitReferences.contains(meeting.id)
        }
        let revisions = Dictionary(uniqueKeysWithValues: candidates.compactMap { m in folders.revision(of: m.id).map { (m.id, $0) } })
        var moves: [MeetingID: UUID?] = [:], proposals: [String: [MeetingID]] = [:]
        for meeting in candidates {
            try Task.checkCancellation()
            let payload: [String: Any] = ["folders": options, "meeting": description(meeting), "request": question, "interactive": !automatic]
            let input = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            let choice = try await AssistantGeneration.chooseFolder(provider: provider, input: input)
            if Set(choice.candidates).count == 1, let value = choice.candidates.first, let id = UUID(uuidString: value), options.contains(where: { $0["id"] == id.uuidString }), folders.folder(of: meeting.id) != id {
                moves.updateValue(id, forKey: meeting.id)
            } else if !automatic, choice.candidates.isEmpty, !choice.proposal.isEmpty {
                proposals[String(choice.proposal.prefix(80)), default: []].append(meeting.id)
            }
        }
        try Task.checkCancellation()
        moves = moves.filter { id, destination in folders.revision(of: id) == revisions[id] && folders.folders.contains { $0.id == destination } }
        let changed = folders.move(moves, origin: automatic ? .automatic : .assistant)
        return FilingResult(batch: changed ? folders.latestBatchID : nil, moved: changed ? moves.count : 0,
            proposals: proposals.keys.sorted().map { FolderProposal(name: $0, meetings: proposals[$0] ?? [], revisions: revisions) })
    }
    private static func description(_ meeting: Meeting) -> String {
        let sample = meeting.outputs.summary?.headline ?? meeting.utterances.prefix(8).map(\.text).joined(separator: " ")
        return "\(meeting.metadata.title): \(sample.prefix(400))"
    }
}
