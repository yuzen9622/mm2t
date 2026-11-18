import Foundation
import Observation

@MainActor @Observable
public final class TodoStatus {
    private struct Anchor: Codable {
        let fingerprint: String
        let done: Bool
    }
    public private(set) var done: Set<String> = []
    public private(set) var storageError: String?
    public var snapshot: TodoSnapshot {
        .init(done: done, anchors: anchors.mapValues(\.fingerprint), anchorMarks: anchors.mapValues(\.done), storageError: storageError)
    }
    @ObservationIgnored public var onToggle: ((String, Bool) -> Void)?
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var anchors: [String: Anchor] = [:]
    @ObservationIgnored private var loadFailed = false
    private var anchorFile: URL { file.deletingLastPathComponent().appending(path: "todo-anchors.json") }

    public init(file: URL) {
        self.file = file
        do {
            if FileManager.default.fileExists(atPath: file.path) { done = Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: file))) }
            if FileManager.default.fileExists(atPath: anchorFile.path) { anchors = try JSONDecoder().decode([String: Anchor].self, from: Data(contentsOf: anchorFile)) }
        } catch { storageError = String(describing: error); loadFailed = true }
    }

    public static func id(meeting: some CustomStringConvertible, index: Int) -> String { "\(meeting)#\(index)" }
    public func isDone(_ id: String) -> Bool { done.contains(id) }

    public func toggle(_ id: String, anchor: String? = nil) {
        let value = !done.contains(id)
        if write(id, done: value, anchor: anchor) { onToggle?(id, value) }
    }

    public func set(_ id: String, done: Bool) {
        guard self.done.contains(id) != done else { return }
        _ = write(id, done: done, anchor: nil)
    }

    private func write(_ id: String, done value: Bool, anchor: String?) -> Bool {
        guard !loadFailed else { return false }
        var next = done
        if value { next.insert(id) } else { next.remove(id) }
        var nextAnchors = anchors
        if let anchor { nextAnchors[id] = .init(fingerprint: anchor, done: value) }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // An interrupted pair of writes has mismatched mark/anchor states and is treated as unverified.
            try JSONEncoder().encode(nextAnchors).write(to: anchorFile, options: .atomic)
            try JSONEncoder().encode(next.sorted()).write(to: file, options: .atomic)
            done = next; anchors = nextAnchors; storageError = nil
            return true
        } catch { storageError = String(describing: error); return false }
    }
}
