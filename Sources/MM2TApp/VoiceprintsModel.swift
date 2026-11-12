import Foundation
import MM2TCore
import Observation

public struct PersonRow: Hashable, Sendable, Identifiable {
    public let id: PersonID
    public let name: String
    public let voiceprintCount: Int
    /// Where the stored vectors were heard; empty for vectors stored before this was recorded.
    public let channels: Set<VoiceChannel>
}

/// The local biometric database: view, rename, delete (stories 44, 45).
@MainActor @Observable
public final class VoiceprintsModel {
    public private(set) var rows: [PersonRow] = []
    public private(set) var errorMessage: String?

    @ObservationIgnored private let store: VoiceprintStore

    public init(store: VoiceprintStore) {
        self.store = store
    }

    public func reload() async {
        rows = await store.allPersons()
            .map { PersonRow(id: $0.id, name: $0.name, voiceprintCount: $0.embeddings.count, channels: $0.channels) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func rename(_ id: PersonID, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        await perform { try await $0.rename(id, to: name) }
    }

    /// Removes the person and every vector from disk. Meetings keep the speaker, now unnamed.
    public func delete(_ id: PersonID) async {
        await perform { try await $0.delete(id) }
    }

    private func perform(_ change: (VoiceprintStore) async throws -> Void) async {
        do {
            try await change(store)
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
        await reload()
    }
}
