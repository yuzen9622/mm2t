import Foundation

/// Scratch space under the package's `.build`, which is git-ignored and on the same disk as the repo.
func scratchDirectory() throws -> URL {
    let url = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: ".build/test-scratch/local-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Real on-device models in the app's layout (`transcription/…`, `llm/…`), from `MM2T_LOCAL_MODELS`.
/// Unset on CI, where the tests that need weights skip.
enum RealModels {
    static var root: URL? {
        ProcessInfo.processInfo.environment["MM2T_LOCAL_MODELS"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
    }
}

/// A fake Hugging Face at the URLSession boundary, answering the tree API and file downloads
/// (with HTTP Range) from an in-memory repo.
final class FakeHub: @unchecked Sendable {
    struct Seen: Equatable { let path: String; let range: String? }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var hubs: [String: FakeHub] = [:]

    let id = UUID().uuidString
    let files: [String: Data]
    let failing: Set<String>
    private let lock = NSLock()
    private var seen: [Seen] = []

    init(files: [String: Data], failing: Set<String> = []) {
        self.files = files
        self.failing = failing
        Self.lock.withLock { Self.hubs[id] = self }
    }

    deinit { Self.lock.withLock { _ = Self.hubs.removeValue(forKey: id) } }

    var configuration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeHubProtocol.self]
        config.httpAdditionalHeaders = [FakeHubProtocol.header: id]
        return config
    }

    var requests: [Seen] { lock.withLock { seen } }

    static func hub(_ id: String) -> FakeHub? { lock.withLock { hubs[id] } }

    func answer(_ request: URLRequest) -> (Int, [String: String], Data) {
        let path = request.url!.path
        let range = request.value(forHTTPHeaderField: "Range")
        lock.withLock { seen.append(Seen(path: path, range: range)) }
        if path.contains("/api/models/") {
            let entries = files.keys.sorted().map { ["type": "file", "path": $0, "size": files[$0]!.count] as [String: Any] }
                + [["type": "directory", "path": "TextDecoder.mlmodelc", "size": 0]]
            return (200, [:], try! JSONSerialization.data(withJSONObject: entries))
        }
        guard let marker = path.range(of: "/resolve/") else { return (404, [:], Data()) }
        let file = path[marker.upperBound...].split(separator: "/", maxSplits: 1).last.map(String.init) ?? ""
        if failing.contains(file) { return (500, [:], Data()) }
        guard let body = files[file] else { return (404, [:], Data()) }
        if let range, let start = Int(range.dropFirst("bytes=".count).dropLast()) {
            return (206, ["Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)"], body.subdata(in: start..<body.count))
        }
        return (200, [:], body)
    }
}

final class FakeHubProtocol: URLProtocol, @unchecked Sendable {
    static let header = "X-MM2T-Hub"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: Self.header), let hub = FakeHub.hub(id) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (status, headers, body) = hub.answer(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
