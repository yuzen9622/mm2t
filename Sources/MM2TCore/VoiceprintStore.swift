import Foundation

public struct Person: Codable, Hashable, Sendable, Identifiable {
    public let id: PersonID
    public internal(set) var name: String
    public internal(set) var embeddings: [Embedding]
}

public struct MatchThresholds: Hashable, Sendable {
    public let autoName: Double
    public let suggest: Double

    public init(autoName: Double, suggest: Double) {
        precondition(suggest <= autoName, "suggest threshold must not exceed autoName threshold")
        self.autoName = autoName
        self.suggest = suggest
    }
}

public enum VoiceprintMatch: Hashable, Sendable {
    case autoName(PersonID, similarity: Double)
    case suggest(PersonID, similarity: Double)
    case none
}

public enum VoiceprintError: Error, Equatable {
    case unknownPerson(PersonID)
}

/// Local biometric database. Only user actions write to it; automatic matches never add vectors.
public actor VoiceprintStore {
    private let fileURL: URL
    private var persons: [Person]

    /// Loads `fileURL` if it exists, otherwise starts empty.
    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        persons = FileManager.default.fileExists(atPath: fileURL.path)
            ? try JSONFile.read([Person].self, from: fileURL)
            : []
    }

    public func allPersons() -> [Person] { persons }

    public func person(_ id: PersonID) -> Person? { persons.first { $0.id == id } }

    public func names() -> [PersonID: String] {
        Dictionary(uniqueKeysWithValues: persons.map { ($0.id, $0.name) })
    }

    public func person(named name: String) -> Person? {
        persons.first { $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame }
    }

    /// Best similarity between any of the cluster's vectors and any vector of any person.
    public func match(_ embeddings: [Embedding], thresholds: MatchThresholds) -> VoiceprintMatch {
        var best: (PersonID, Double)?
        for person in persons {
            for stored in person.embeddings {
                for candidate in embeddings {
                    let similarity = candidate.cosineSimilarity(to: stored)
                    if similarity > (best?.1 ?? -.infinity) { best = (person.id, similarity) }
                }
            }
        }
        guard let (id, similarity) = best else { return .none }
        if similarity >= thresholds.autoName { return .autoName(id, similarity: similarity) }
        if similarity >= thresholds.suggest { return .suggest(id, similarity: similarity) }
        return .none
    }

    @discardableResult
    public func addPerson(name: String, embeddings: [Embedding] = []) throws -> PersonID {
        let person = Person(id: PersonID(), name: name, embeddings: embeddings)
        try save(persons + [person])
        return person.id
    }

    public func addEmbeddings(_ embeddings: [Embedding], to id: PersonID) throws {
        try update(id) { person in
            person.embeddings += embeddings.filter { !$0.values.isEmpty && !person.embeddings.contains($0) }
        }
    }

    public func rename(_ id: PersonID, to name: String) throws {
        try update(id) { $0.name = name }
    }

    /// Moves every vector of `source` into `target` and deletes `source`.
    public func merge(_ source: PersonID, into target: PersonID) throws {
        guard source != target else { return }
        guard let from = person(source) else { throw VoiceprintError.unknownPerson(source) }
        try update(target) { $0.embeddings += from.embeddings }
        try save(persons.filter { $0.id != source })
    }

    /// Removes the person and all their vectors from disk.
    public func delete(_ id: PersonID) throws {
        guard person(id) != nil else { throw VoiceprintError.unknownPerson(id) }
        try save(persons.filter { $0.id != id })
    }

    private func update(_ id: PersonID, _ change: (inout Person) -> Void) throws {
        guard let index = persons.firstIndex(where: { $0.id == id }) else {
            throw VoiceprintError.unknownPerson(id)
        }
        var next = persons
        change(&next[index])
        try save(next)
    }

    private func save(_ next: [Person]) throws {
        try JSONFile.write(next, to: fileURL)
        persons = next
    }
}
