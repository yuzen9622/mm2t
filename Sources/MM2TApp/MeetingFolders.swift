import Foundation
import MM2TCore
import Observation

@MainActor @Observable public final class MeetingFolders {
    public struct Folder: Identifiable, Codable, Equatable, Sendable {
        public let id: UUID
        public var name: String
    }
    public enum Origin: String, Codable, Sendable { case manual, assistant, automatic }
    private struct Placement: Codable {
        var folder: UUID?
        var origin: Origin
        var revision: UUID
    }
    private struct Change: Codable {
        var id: MeetingID
        var previous: Placement?
        var revision: UUID
    }
    private struct State: Codable {
        var pending: Set<MeetingID>?
        var folders: [Folder] = []
        var placements: [MeetingID: Placement] = [:]
        var batches: [[Change]] = []
    }
    private let file: URL
    private var state: State
    public var selected: UUID?
    public var errorMessage: String?
    public var folders: [Folder] { state.folders }
    var searchPriority: SearchQuery.Priority {
        if let selected { return .init(ids: Set(state.placements.filter { $0.value.folder == selected }.keys)) }
        return .init(ids: Set(state.placements.filter { $0.value.folder != nil }.keys), inverted: true)
    }
    public var canUndo: Bool { !state.batches.isEmpty }
    public init(file: URL) throws {
        self.file = file
        state = FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) : State()
    }
    func recorded(_ id: MeetingID) {
        var next = state
        next.pending = (next.pending ?? []).union([id]); _ = save(next)
    }
    func claimRecording(_ id: MeetingID) -> Bool {
        var next = state
        guard next.pending?.remove(id) != nil else { return false }
        return save(next)
    }
    public func folder(of id: MeetingID) -> UUID? { state.placements[id]?.folder }
    public func isManuallyFiled(_ id: MeetingID) -> Bool { state.placements[id]?.origin == .manual }
    public func revision(of id: MeetingID) -> UUID? { state.placements[id]?.revision }
    @discardableResult public func create(_ name: String) -> UUID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let existing = folders.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) { return existing.id }
        let folder = Folder(id: UUID(), name: name)
        var next = state; next.folders.append(folder)
        return save(next) ? folder.id : nil
    }
    public func canRename(_ id: UUID, to name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && folders.contains { $0.id == id }
            && !folders.contains { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }
    public func rename(_ id: UUID, to name: String) -> Bool {
        guard canRename(id, to: name), let index = folders.firstIndex(where: { $0.id == id }) else { return false }
        var next = state
        next.folders[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return save(next)
    }
    public func delete(_ id: UUID) {
        var next = state
        next.folders.removeAll { $0.id == id }
        for (meeting, placement) in next.placements where placement.folder == id {
            next.placements[meeting] = Placement(folder: nil, origin: .manual, revision: UUID())
        }
        if save(next), selected == id { selected = nil }
    }
    @discardableResult public func move(_ destinations: [MeetingID: UUID?], origin: Origin, joining batchID: UUID? = nil) -> Bool {
        persistMoves(destinations, origin: origin, joining: batchID, startingFrom: state) != nil
    }

    func canApply(_ proposal: FolderProposal) -> Bool {
        guard !proposal.meetings.isEmpty, Set(proposal.meetings).count == proposal.meetings.count,
              proposal.meetings.allSatisfy({ revision(of: $0) == proposal.revisions[$0] }) else { return false }
        if let destination = proposal.destination {
            return folders.contains { $0.id == destination && $0.name == proposal.name }
        }
        return !proposal.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !folders.contains { $0.name.localizedCaseInsensitiveCompare(proposal.name) == .orderedSame }
    }

    func apply(_ proposal: FolderProposal, joining batchID: UUID?) -> UUID? {
        guard canApply(proposal) else { return nil }
        var next = state
        let destination = proposal.destination ?? UUID()
        if proposal.destination == nil { next.folders.append(Folder(id: destination, name: proposal.name)) }
        let moves = Dictionary(uniqueKeysWithValues: proposal.meetings.map { ($0, Optional(destination)) })
        return persistMoves(moves, origin: .assistant, joining: batchID, startingFrom: next)
    }

    private func persistMoves(_ destinations: [MeetingID: UUID?], origin: Origin, joining batchID: UUID?, startingFrom state: State) -> UUID? {
        var next = state, changes: [Change] = []
        for (id, destination) in destinations {
            guard destination == nil || next.folders.contains(where: { $0.id == destination }) else { return nil }
            let prior = next.placements[id]
            guard prior?.folder != destination, origin != .automatic || prior == nil else { continue }
            let revision = UUID()
            changes.append(Change(id: id, previous: prior, revision: revision))
            next.placements[id] = Placement(folder: destination, origin: origin, revision: revision)
        }
        guard var batch = changes.first?.revision else { return nil }
        if let batchID, let index = next.batches.firstIndex(where: { $0.first?.revision == batchID }) {
            next.batches[index] += changes
            batch = batchID
        } else { next.batches.append(changes) }
        return save(next) ? batch : nil
    }
    public var latestBatchID: UUID? { state.batches.last?.first?.revision }
    public func undo(batchID: UUID? = nil) {
        var next = state
        guard let index = next.batches.lastIndex(where: { batchID == nil || $0.first?.revision == batchID }) else { return }
        let batch = next.batches.remove(at: index)
        for change in batch.reversed() where next.placements[change.id]?.revision == change.revision {
            var previous = change.previous
            if let folder = previous?.folder, !folders.contains(where: { $0.id == folder }) { previous?.folder = nil }
            next.placements[change.id] = previous
        }
        _ = save(next)
    }
    private func save(_ next: State) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
            state = next
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
}
