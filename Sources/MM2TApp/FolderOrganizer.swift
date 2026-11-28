import Foundation
import MM2TCore
import MM2TProviders

public struct FolderProposal: Codable, Sendable {
    public var name: String
    public var meetings: [MeetingID]
    var revisions: [MeetingID: UUID]
    public var destination: UUID?
    public var checkedCount: Int?

    public struct Row: Identifiable, Equatable, Sendable {
        public let id: MeetingID
        public let title: String
        public let date: Date
    }
}

struct FilingResult: Sendable {
    var batch: UUID?
    var moved: Int
    var checked: Int
    var alreadyInPlace: Int
    var proposals: [FolderProposal]
}

@MainActor enum FolderOrganizer {
    enum Mode: String { case automatic, file, unfiledOnly, reorganize }

    static func previewMode(provider: any LLMProvider, question: String) async throws -> Mode? {
        let choice = try await AssistantGeneration.userDirective(provider: provider, question: question,
            rule: """
                Classify the current request in this meeting archive. \(AssistantGeneration.filingRequest)
                reorganize: organize folders, reclassify already-filed meetings, or categorize the entire archive.
                unfiledOnly: explicitly organize only unfiled meetings.
                file: file meetings, including a specific meeting or selection.
                none: read-only, unsupported folder operation, or unclear whether the user wants filing.
                """, choices: ["reorganize", "unfiledOnly", "file", "none"])
        return Mode(rawValue: choice)
    }

    static func run(_ folders: MeetingFolders, library: MeetingLibrary, provider: any LLMProvider, question: String, scope: Set<MeetingID>?, mode: Mode, explicitReferences: Set<MeetingID> = []) async throws -> FilingResult {
        let automatic = mode == .automatic
        let meetings = try await library.list()
        let destinations = folders.folders
        let options = destinations.map { folder in
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
                if !value.isEmpty {
                    guard matches.count == 1 else { throw AssistantQueryError.invalid("Meeting title is ambiguous") }
                    named = matches[0].id
                }
            }
        }
        let candidates = meetings.filter { meeting in
            if let scope, !scope.contains(meeting.id) { return false }
            if let named, meeting.id != named { return false }
            if folders.folder(of: meeting.id) == nil { return true }
            return mode == .reorganize || (mode == .file && (named != nil || explicitReferences.contains(meeting.id)))
        }
        let revisions = Dictionary(uniqueKeysWithValues: candidates.compactMap { m in folders.revision(of: m.id).map { (m.id, $0) } })
        var moves: [MeetingID: UUID?] = [:]
        var proposals: [String: FolderProposal] = [:]
        var alreadyInPlace = 0
        for meeting in candidates {
            try Task.checkCancellation()
            let payload: [String: Any] = ["folders": options, "meeting": description(meeting), "request": question, "interactive": !automatic]
            let input = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            let choice = try await AssistantGeneration.chooseFolder(provider: provider, input: input)
            let destination: MeetingFolders.Folder?
            let name: String
            if choice.candidates.isEmpty {
                guard !automatic else { continue }
                let suggested = String(choice.proposal.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !suggested.isEmpty else { continue }
                destination = destinations.first { $0.name.localizedCaseInsensitiveCompare(suggested) == .orderedSame }
                name = destination?.name ?? suggested
            } else {
                guard Set(choice.candidates).count == 1, let raw = choice.candidates.first,
                      let folder = destinations.first(where: { $0.id == UUID(uuidString: raw) }) else { continue }
                name = folder.name
                destination = folder
            }
            if let destination, folders.folder(of: meeting.id) == destination.id {
                alreadyInPlace += 1
                continue
            }
            if automatic {
                if let destination { moves.updateValue(destination.id, forKey: meeting.id) }
            } else {
                let key = name.lowercased()
                var proposal = proposals[key] ?? FolderProposal(name: name, meetings: [], revisions: [:],
                    destination: destination?.id, checkedCount: candidates.count)
                proposal.meetings.append(meeting.id)
                proposal.revisions[meeting.id] = revisions[meeting.id]
                proposals[key] = proposal
            }
        }
        try Task.checkCancellation()
        moves = moves.filter { id, destination in folders.revision(of: id) == revisions[id] && folders.folders.contains { $0.id == destination } }
        let changed = automatic && folders.move(moves, origin: .automatic)
        return FilingResult(batch: changed ? folders.latestBatchID : nil, moved: changed ? moves.count : 0,
            checked: candidates.count, alreadyInPlace: alreadyInPlace, proposals: proposals.values.sorted { $0.name < $1.name })
    }
    private static func description(_ meeting: Meeting) -> String {
        let sample = meeting.outputs.summary?.headline ?? meeting.utterances.prefix(8).map(\.text).joined(separator: " ")
        return "\(meeting.metadata.title): \(sample.prefix(400))"
    }
}


extension MeetingLibrary {
    func filingRows(for ids: [MeetingID]) throws -> [FolderProposal.Row] {
        try ids.map { id in
            let record = try meeting(id)
            return .init(id: id, title: record.metadata.title, date: record.metadata.startedAt)
        }
    }
}
