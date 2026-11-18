import Foundation
import Observation

public struct AssistantConversation: Identifiable, Codable, Sendable {
    public var version = 1
    public var id = UUID()
    public var updatedAt = Date()
    public var turns: [AssistantTurn] = []
    public var ledger = AssistantLedger()
    public var title: String { String((turns.first?.question ?? "").prefix(80)) }
    public init() {}

    func history(memoryRevision: UUID?, limit: Int = 4_000) -> String {
        var blocks: [String] = []
        var size = 0
        for (distance, turn) in turns.reversed().enumerated() where !turn.memoryManagement {
            let sources = turn.citedSources.map { "\($0.id): \($0.title)" }.joined(separator: "\n")
            let coverage = turn.steps.compactMap { $0.result?.coverage }.filter { !$0.isEmpty }.suffix(1).joined()
            let canUseAnswer = turn.memoryRevision == memoryRevision
            let question = canUseAnswer ? turn.question : "[Earlier user wording omitted after memory settings changed]"
            let answer = canUseAnswer && distance < 3 ? turn.answer.text : "[Prior wording omitted; re-read sources for detail]"
            let block = "User: \(question)\nAssistant: \(answer)\nCited items in answer order:\n\(sources)\nLast query coverage: \(coverage)\n"
            if size + block.count <= limit {
                blocks.insert(block, at: 0); size += block.count
            } else {
                let compact = "User: \(question)\n[Answer omitted for budget; do not infer numbered item order.]\nSources in citation order:\n\(sources)\n\(coverage)\n"
                if size + compact.count <= limit { blocks.insert(compact, at: 0); size += compact.count }
                break
            }
        }
        return blocks.joined(separator: "\n")
    }
}

@MainActor @Observable
public final class AssistantConversations {
    public private(set) var records: [AssistantConversation] = []
    public private(set) var errors: [String] = []
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var leases: [UUID: UUID] = [:]
    @ObservationIgnored private var pending: [UUID: AssistantConversation] = [:]

    public init(directory: URL) {
        self.directory = directory
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                do {
                    var record = try JSONDecoder().decode(AssistantConversation.self, from: Data(contentsOf: file))
                    guard record.version == 1, file.deletingPathExtension().lastPathComponent == record.id.uuidString else {
                        throw AssistantQueryError.invalid("Unsupported conversation")
                    }
                    for index in record.turns.indices where record.turns[index].state == .running {
                        record.turns[index].state = .stopped
                        for step in record.turns[index].steps.indices where record.turns[index].steps[step].state == .running {
                            record.turns[index].steps[step].state = .stopped
                        }
                    }
                    records.append(record)
                } catch { errors.append("\(file.lastPathComponent): \(error)") }
            }
            records.sort { $0.updatedAt > $1.updatedAt }
        } catch { errors.append(String(describing: error)) }
    }

    func open(_ id: UUID?, owner: UUID) throws -> AssistantConversation {
        let record: AssistantConversation
        if let id {
            guard let found = pending[id] ?? records.first(where: { $0.id == id }) else { throw AssistantQueryError.invalid("Conversation no longer exists") }
            record = found
        } else { record = AssistantConversation() }
        guard leases[record.id] == nil || leases[record.id] == owner else { throw AssistantQueryError.invalid("Conversation is open in another window") }
        leases[record.id] = owner
        return record
    }

    func availableRecent() -> UUID? {
        pending.values.sorted { $0.updatedAt > $1.updatedAt }.first { leases[$0.id] == nil }?.id
            ?? records.first { leases[$0.id] == nil }?.id
    }
    func isUnsaved(_ id: UUID) -> Bool { pending[id] != nil }
    func release(owner: UUID) { leases = leases.filter { $0.value != owner } }
    func release(_ id: UUID, owner: UUID) { if leases[id] == owner { leases[id] = nil } }

    func save(_ record: AssistantConversation, owner: UUID) throws {
        guard leases[record.id] == owner else { throw AssistantQueryError.invalid("Conversation belongs to another window") }
        var record = record; record.updatedAt = Date()
        pending[record.id] = record
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: file(record.id), options: .atomic)
        pending[record.id] = nil
        records.removeAll { $0.id == record.id }; records.insert(record, at: 0)
    }

    public func delete(_ id: UUID) throws {
        guard leases[id] == nil else { throw AssistantQueryError.invalid("Close this conversation before deleting it") }
        let target = file(id)
        guard records.contains(where: { $0.id == id }) else { throw AssistantQueryError.invalid("Unknown conversation") }
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        records.removeAll { $0.id == id }
    }

    private func file(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).json") }
}
