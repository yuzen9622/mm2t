import Foundation
import Observation

/// Which to-dos are done, shared by the home screen, the meeting view and the Reminders sync.
/// A to-do id is `"<meeting id>#<index>"`.
@MainActor @Observable
public final class TodoStatus {
    public private(set) var done: Set<String>
    /// Called with every change the user makes here, but not with `set(_:done:)`.
    @ObservationIgnored public var onToggle: ((String, Bool) -> Void)?
    @ObservationIgnored private let file: URL

    public init(file: URL) {
        self.file = file
        done = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: file))) ?? [])
    }

    public static func id(meeting: some CustomStringConvertible, index: Int) -> String { "\(meeting)#\(index)" }

    public func isDone(_ id: String) -> Bool { done.contains(id) }

    public func toggle(_ id: String) {
        let isDone = !done.contains(id)
        set(id, done: isDone)
        onToggle?(id, isDone)
    }

    /// Records a change that came from elsewhere, such as Reminders.
    public func set(_ id: String, done isDone: Bool) {
        guard done.contains(id) != isDone else { return }
        if isDone { done.insert(id) } else { done.remove(id) }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(done.sorted()).write(to: file, options: .atomic)
    }
}
