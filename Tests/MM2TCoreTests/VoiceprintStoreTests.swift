import Foundation
import Testing
@testable import MM2TCore

@Suite struct VoiceprintStoreTests {
    @Test func matchesAgainstAnyOfAPersonsVectorsWithTwoThresholds() async throws {
        let url = try temporaryDirectory().appending(path: "v.json")
        let store = try VoiceprintStore(fileURL: url)
        let dana = try await store.addPerson(name: "Dana", embeddings: [Embedding([1, 0]), Embedding([0, 1])])

        let strong = await store.match([Embedding([0.05, 1])], thresholds: thresholds)
        let middling = await store.match([Embedding([1, 1])], thresholds: thresholds)
        let weak = await store.match([Embedding([-1, -1])], thresholds: thresholds)

        guard case .autoName(dana, _) = strong, case .suggest(dana, _) = middling else {
            Issue.record("unexpected \(strong), \(middling)")
            return
        }
        #expect(weak == .none)
    }

    @Test func persistsRenameMergeAndDeleteAcrossReloads() async throws {
        let url = try temporaryDirectory().appending(path: "v.json")
        let store = try VoiceprintStore(fileURL: url)
        let a = try await store.addPerson(name: "A", embeddings: [Embedding([1, 0])])
        let b = try await store.addPerson(name: "B", embeddings: [Embedding([0, 1])])
        try await store.rename(a, to: "Alice")
        try await store.merge(b, into: a)

        let reloaded = try VoiceprintStore(fileURL: url)
        #expect(await reloaded.allPersons().map(\.name) == ["Alice"])
        #expect(await reloaded.person(a)?.embeddings == [Embedding([1, 0]), Embedding([0, 1])])
    }

    @Test func deleteRemovesEveryVectorFromDisk() async throws {
        let url = try temporaryDirectory().appending(path: "v.json")
        let store = try VoiceprintStore(fileURL: url)
        let keep = try await store.addPerson(name: "Keep", embeddings: [Embedding([0.25, 0.5])])
        let gone = try await store.addPerson(name: "Gone", embeddings: [Embedding([0.125, 0.875]), Embedding([0.375, 0.625])])

        try await store.delete(gone)

        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(!onDisk.contains("Gone"))
        #expect(!onDisk.contains("0.875") && !onDisk.contains("0.625"))
        #expect(onDisk.contains("Keep"))
        #expect(try await VoiceprintStore(fileURL: url).allPersons().map(\.id) == [keep])
        #expect(await store.match([Embedding([0.125, 0.875])], thresholds: MatchThresholds(autoName: 0.99, suggest: 0.99)) == .none)
    }
}
