import Foundation
import Observation

public struct AssistantPreference: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var text: String
    public var scope: String
    public var enabled = true
    public var sourceTurn: UUID?
    public var createdAt = Date()
    public var updatedAt = Date()
}

@MainActor @Observable
public final class AssistantPreferences {
    private struct State: Codable {
        var version = 1
        var revision = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        var enabled = true
        var items: [AssistantPreference] = []
    }
    private var state = State()
    public var revision: UUID { state.revision }
    public var enabled: Bool { state.enabled }
    public var items: [AssistantPreference] { state.items }
    public private(set) var error: String?
    @ObservationIgnored private let file: URL

    public init(file: URL) {
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let loaded = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            guard loaded.version == 1 else { throw AssistantQueryError.invalid("Unsupported memory format") }
            state = loaded
        } catch { self.error = String(describing: error) }
    }

    public func setEnabled(_ value: Bool) throws { var next = state; next.enabled = value; try save(next) }

    public func put(id: UUID? = nil, text: String, scope: String = "", enabled: Bool? = nil, sourceTurn: UUID? = nil) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 300, scope.count <= 100 else { throw AssistantQueryError.invalid("Preference must contain 1–300 characters; scope at most 100") }
        var next = state
        if let id {
            guard let index = next.items.firstIndex(where: { $0.id == id }) else { throw AssistantQueryError.invalid("Preference no longer exists") }
            next.items[index].text = text; next.items[index].scope = scope
            if let enabled { next.items[index].enabled = enabled }
            next.items[index].updatedAt = Date()
        } else {
            guard next.items.count < 100 else { throw AssistantQueryError.invalid("At most 100 preferences") }
            next.items.append(.init(text: text, scope: scope, enabled: enabled ?? true, sourceTurn: sourceTurn))
        }
        try save(next)
    }

    public func delete(_ id: UUID) throws { var next = state; next.items.removeAll { $0.id == id }; try save(next) }

    public func context(for question: String, limit: Int = 1_200) -> String {
        guard state.enabled, error == nil else { return "" }
        let candidates = state.items.filter { $0.enabled && ($0.scope.isEmpty || question.localizedStandardContains($0.scope)) }
            .sorted { $0.scope.isEmpty != $1.scope.isEmpty ? $0.scope.isEmpty : $0.updatedAt > $1.updatedAt }
        var result = ""
        for item in candidates {
            let line = "- " + item.text + "\n"
            if result.count + line.count <= limit { result += line }
        }
        return result
    }

    private func save(_ next: State) throws {
        guard error == nil else { throw AssistantQueryError.invalid("Memory file could not be read; preserving it rather than overwriting") }
        var next = next
        next.revision = UUID()
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
            state = next
        } catch { throw error }
    }
}
