import Foundation
import Testing
@testable import MM2TLocal

@Suite struct ModelSnapshotTests {
    let files = [
        "TextDecoder.mlmodelc/weights/weight.bin": Data(repeating: 7, count: 300_000),
        "TextDecoder.mlmodelc/coremldata.bin": Data("decoder".utf8),
        "config.json": Data("{}".utf8),
        "README.md": Data("not wanted".utf8),
    ]

    func snapshot(in directory: URL, revision: String = "abc123") -> ModelSnapshot {
        ModelSnapshot(
            directory: directory.appending(path: "model"),
            sources: [HubFiles(repo: "someone/model", revision: revision, paths: ["TextDecoder.mlmodelc/", "config.json"])],
            approximateBytes: 300_000)
    }

    @Test func installsOnlyThePinnedFilesAndThenReadsAsInstalled() async throws {
        let directory = try scratchDirectory()
        let hub = FakeHub(files: files)
        let model = snapshot(in: directory)
        #expect(!model.isDownloaded)

        let fractions = Fractions()
        try await model.download(configuration: hub.configuration) { fractions.append($0) }

        #expect(model.isDownloaded)
        let installed = model.directory
        #expect(try Data(contentsOf: installed.appending(path: "TextDecoder.mlmodelc/weights/weight.bin")) == files["TextDecoder.mlmodelc/weights/weight.bin"])
        #expect(try Data(contentsOf: installed.appending(path: "config.json")) == Data("{}".utf8))
        #expect(!FileManager.default.fileExists(atPath: installed.appending(path: "README.md").path))
        #expect(fractions.values.last == 1)
        #expect(fractions.values == fractions.values.sorted(), "progress never goes backwards")
        #expect(hub.requests.contains { $0.path == "/api/models/someone/model/tree/abc123" }, "the listing is pinned too")
        #expect(hub.requests.contains { $0.path == "/someone/model/resolve/abc123/config.json" })
    }

    @Test func aNewPinnedRevisionMakesTheInstalledCopyStale() async throws {
        let directory = try scratchDirectory()
        try await snapshot(in: directory).download(configuration: FakeHub(files: files).configuration)
        #expect(!snapshot(in: directory, revision: "def456").isDownloaded)
    }

    @Test func anInterruptedDownloadIsNotInstalledAndTheNextOneResumes() async throws {
        let directory = try scratchDirectory()
        let model = snapshot(in: directory)
        await #expect(throws: LocalModelError.self) {
            try await model.download(configuration: FakeHub(files: files, failing: ["config.json"]).configuration)
        }
        #expect(!model.isDownloaded)

        let weights = model.directory.appending(path: "TextDecoder.mlmodelc/weights/weight.bin")
        let half = try Data(contentsOf: weights).prefix(100_000)
        try FileManager.default.removeItem(at: weights)
        try half.write(to: weights.appendingPathExtension("part"))

        let hub = FakeHub(files: files)
        try await model.download(configuration: hub.configuration)
        #expect(model.isDownloaded)
        #expect(try Data(contentsOf: weights) == files["TextDecoder.mlmodelc/weights/weight.bin"])
        #expect(hub.requests.contains { $0.path.hasSuffix("weight.bin") && $0.range == "bytes=100000-" })
        #expect(!hub.requests.contains { $0.path.hasSuffix("coremldata.bin") }, "a finished file is not fetched again")
    }

    @Test func aPinnedFileMissingFromTheRepoFailsInsteadOfInstallingHalfAModel() async throws {
        let directory = try scratchDirectory()
        let model = ModelSnapshot(
            directory: directory.appending(path: "model"),
            sources: [HubFiles(repo: "someone/model", revision: "abc123", paths: ["tokenizer.json"])],
            approximateBytes: 1)
        await #expect(throws: LocalModelError.self) { try await model.download(configuration: FakeHub(files: files).configuration) }
        #expect(!model.isDownloaded)
    }

    @Test func followsTheHubsNextPageLink() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://huggingface.co/api/models/a/b/tree/c")!, statusCode: 200, httpVersion: nil,
            headerFields: ["Link": #"<https://huggingface.co/api/models/a/b/tree/c?cursor=xyz>; rel="next""#])!
        #expect(ModelSnapshot.nextPage(response)?.absoluteString == "https://huggingface.co/api/models/a/b/tree/c?cursor=xyz")
    }
}

final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func append(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}
