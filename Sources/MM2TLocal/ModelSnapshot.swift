import Foundation

public enum LocalModelError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The files are not on disk. Running a model never downloads; the app calls `ModelSnapshot.download`.
    case missing(directory: URL)
    case downloadFailed(String)

    public var description: String {
        switch self {
        case .missing(let directory): "model files missing in \(directory.path)"
        case .downloadFailed(let reason): reason
        }
    }
}

/// Files from one Hugging Face repo, pinned to a commit so every install gets the same bytes.
public struct HubFiles: Hashable, Sendable {
    public let repo: String
    public let revision: String
    /// Repo paths to install; one ending in "/" takes everything under it.
    public let paths: [String]

    public init(repo: String, revision: String, paths: [String]) {
        self.repo = repo
        self.revision = revision
        self.paths = paths
    }

    func includes(_ path: String) -> Bool {
        paths.contains { $0.hasSuffix("/") ? path.hasPrefix($0) : path == $0 }
    }
}

/// An on-device model installed into one directory from pinned Hugging Face files. Installed
/// means a marker naming every pinned revision exists; it is written only after the last file
/// lands, so an interrupted download reads as not installed and the next call resumes it.
public struct ModelSnapshot: Sendable {
    public let directory: URL
    public let sources: [HubFiles]
    /// What the download costs, for the setup screen before the file list is fetched.
    public let approximateBytes: Int64

    public init(directory: URL, sources: [HubFiles], approximateBytes: Int64) {
        self.directory = directory
        self.sources = sources
        self.approximateBytes = approximateBytes
    }

    static let markerName = ".mm2t-snapshot"
    static let hub = URL(string: "https://huggingface.co")!

    var fingerprint: String {
        sources.map { "\($0.repo)@\($0.revision)" }.joined(separator: "\n")
    }

    public var isDownloaded: Bool {
        let marker = try? String(contentsOf: directory.appending(path: Self.markerName), encoding: .utf8)
        return marker == fingerprint
    }

    /// Fetches whatever is missing. `progress` receives 0...1 by bytes. Files already complete are
    /// kept, and a partial file continues from where it stopped.
    public func download(
        configuration: URLSessionConfiguration = .default,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        if isDownloaded { return progress(1) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            var plan: [(source: HubFiles, entry: TreeEntry)] = []
            for source in sources {
                plan += try await listing(source, session: session).map { (source, $0) }
            }
            let total = max(plan.reduce(0) { $0 + $1.entry.size }, 1)
            let counter = ByteCounter { progress(min(Double($0) / Double(total), 0.999)) }
            for (source, entry) in plan {
                let destination = directory.appending(path: entry.path)
                if fileSize(destination) == entry.size {
                    counter.add(entry.size)
                    continue
                }
                try await fetch(source, entry, to: destination, configuration: configuration, counter: counter)
            }
            try fingerprint.write(to: directory.appending(path: Self.markerName), atomically: true, encoding: .utf8)
        } catch let error as LocalModelError {
            throw error
        } catch {
            throw LocalModelError.downloadFailed(String(describing: error))
        }
        progress(1)
    }

    // MARK: Hub

    struct TreeEntry: Decodable, Sendable {
        let type: String
        let path: String
        let size: Int64
    }

    private func listing(_ source: HubFiles, session: URLSession) async throws -> [TreeEntry] {
        var components = URLComponents(
            url: Self.hub.appending(path: "api/models/\(source.repo)/tree/\(source.revision)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        var entries: [TreeEntry] = []
        var next: URL? = components.url
        while let url = next {
            let (data, response) = try await session.data(from: url)
            let http = response as? HTTPURLResponse
            guard http?.statusCode == 200 else {
                throw LocalModelError.downloadFailed("\(source.repo): file list answered \(http?.statusCode ?? 0)")
            }
            entries += try JSONDecoder().decode([TreeEntry].self, from: data)
            next = http.flatMap(Self.nextPage)
        }
        let files = entries.filter { $0.type == "file" && source.includes($0.path) }
        let missing = source.paths.filter { path in !path.hasSuffix("/") && !files.contains { $0.path == path } }
        guard missing.isEmpty, !files.isEmpty else {
            throw LocalModelError.downloadFailed("\(source.repo)@\(source.revision) is missing \(missing)")
        }
        return files
    }

    /// The Hub pages long listings with an RFC 8288 `Link: <url>; rel="next"` header.
    static func nextPage(_ response: HTTPURLResponse) -> URL? {
        guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in link.split(separator: ",") where part.contains("rel=\"next\"") {
            if let open = part.firstIndex(of: "<"), let close = part.firstIndex(of: ">") {
                return URL(string: String(part[part.index(after: open)..<close]))
            }
        }
        return nil
    }

    private func fetch(
        _ source: HubFiles, _ entry: TreeEntry, to destination: URL,
        configuration: URLSessionConfiguration, counter: ByteCounter
    ) async throws {
        let url = Self.hub.appending(path: "\(source.repo)/resolve/\(source.revision)/\(entry.path)")
        let partial = destination.appendingPathExtension("part")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var offset = fileSize(partial) ?? 0
        if offset > entry.size {
            try FileManager.default.removeItem(at: partial)
            offset = 0
        }
        if offset == 0 { FileManager.default.createFile(atPath: partial.path, contents: nil) }
        counter.add(offset)
        try await StreamedFile.fetch(url, offset: offset, to: partial, configuration: configuration, counter: counter)
        guard fileSize(partial) == entry.size else {
            throw LocalModelError.downloadFailed("\(entry.path): expected \(entry.size) bytes, got \(fileSize(partial) ?? 0)")
        }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private let report: @Sendable (Int64) -> Void

    init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }

    func add(_ count: Int64) {
        let total = lock.withLock {
            bytes += count
            return bytes
        }
        report(total)
    }
}

/// One file streamed straight into its destination folder, so a multi-gigabyte model never
/// passes through the system temporary directory.
private final class StreamedFile: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private let offset: Int64
    private let counter: ByteCounter
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    private init(handle: FileHandle, offset: Int64, counter: ByteCounter) {
        self.handle = handle
        self.offset = offset
        self.counter = counter
    }

    static func fetch(
        _ url: URL, offset: Int64, to file: URL, configuration: URLSessionConfiguration, counter: ByteCounter
    ) async throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let delegate = StreamedFile(handle: handle, offset: offset, counter: counter)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 206 where offset > 0:
            completionHandler(.allow)
        case 200:
            if offset > 0 {
                try? handle.truncate(atOffset: 0)
                counter.add(-offset)
            }
            completionHandler(.allow)
        default:
            failure = LocalModelError.downloadFailed("\(dataTask.originalRequest?.url?.lastPathComponent ?? "file") answered \(status)")
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
            counter.add(Int64(data.count))
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let problem = failure ?? error {
            continuation?.resume(throwing: problem)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
