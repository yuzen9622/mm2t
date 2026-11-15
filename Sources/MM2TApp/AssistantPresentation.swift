import Foundation
import MM2TCore
import Observation

public enum AssistantMarkdown {
    public struct Run: Equatable, Identifiable {
        public let offset: Int
        public let text: String
        public let bold: Bool
        public let citation: String?
        public var id: Int { offset }
    }
    public struct Document: Equatable {
        public let runs: [Run]
        public let citationIDs: [String]
        public var plainText: String { runs.map(\.text).joined() }
    }

    public static func parse(_ input: String, known: Set<String>) -> Document {
        let characters = Array(input)
        var index = 0
        var bold = false
        var lineStart = true
        var runs: [Run] = []
        var citations: [String] = []
        func append(_ text: String, at offset: Int, citation: String? = nil) {
            runs.append(Run(offset: offset, text: text, bold: bold, citation: citation))
        }
        while index < characters.count {
            let start = index
            let char = characters[index]
            if char == "*" {
                if index + 1 == characters.count { break }
                if characters[index + 1] == "*" { bold.toggle(); index += 2; continue }
            }
            if char == "[" {
                if index + 1 == characters.count { break }
                if characters[index + 1] == "m" {
                    guard let end = characters[(index + 2)...].firstIndex(of: "]") else { break }
                    let id = String(characters[(index + 1)..<end])
                    if known.contains(id) {
                        if !citations.contains(id) { citations.append(id) }
                        append("\(citations.firstIndex(of: id)! + 1)", at: start, citation: id)
                    }
                    index = end + 1
                    continue
                }
            }
            if lineStart && char == "-" {
                if index + 1 == characters.count { break }
                if characters[index + 1] == " " { append("• ", at: start); index += 2; lineStart = false; continue }
            }
            append(String(char), at: start)
            lineStart = char == "\n"
            index += 1
        }
        return Document(runs: runs, citationIDs: citations)
    }
}

public struct AssistantBatch: Sendable, Equatable {
    public let endOffset: Int
    public let arrived: Date
}

public struct AssistantBatcher {
    public private(set) var text = ""
    public private(set) var batches: [AssistantBatch] = []
    private var pending = ""
    private var lastFlush: Date?
    public init() {}
    public mutating func append(_ delta: String) { pending += delta }
    @discardableResult public mutating func flush(at now: Date, force: Bool = false) -> Bool {
        guard !pending.isEmpty, force || lastFlush == nil || now.timeIntervalSince(lastFlush!) >= 0.05 else { return false }
        text += pending
        pending = ""
        batches.append(.init(endOffset: text.count, arrived: now))
        lastFlush = now
        return true
    }
}

public struct AssistantFollowScroll {
    public private(set) var follows = true
    public private(set) var offset: Double = 0
    public init() {}
    public mutating func userScrolled(offset: Double, bottomDistance: Double) {
        self.offset = max(0, offset)
        follows = bottomDistance <= 40
    }
    public func restoredOffset(contentHeight: Double, viewportHeight: Double) -> Double {
        let bottom = max(0, contentHeight - viewportHeight)
        return follows ? bottom : min(offset, bottom)
    }
    public mutating func sent() { follows = true }
}

public struct AssistantShownContent {
    public enum Element: Hashable {
        case activity(UUID)
        case source(turn: UUID, id: String)
    }
    private var elements: Set<Element> = []
    private var answerOffsets: [UUID: Int] = [:]
    public init() {}
    public func contains(_ element: Element) -> Bool { elements.contains(element) }
    public mutating func insert(_ element: Element) { elements.insert(element) }
    public func settledAnswerOffset(for turn: UUID) -> Int { answerOffsets[turn] ?? 0 }
    public mutating func settleAnswers(_ turns: [AssistantTurn]) {
        for turn in turns { answerOffsets[turn.id] = turn.answer.text.count }
    }
}

@MainActor @Observable
public final class AssistantLayoutState {
    public private(set) var active = false
    public private(set) var visible = true
    public private(set) var canvasShown = false
    public init(active: Bool = false) {
        self.active = active
        canvasShown = active
    }

    public func transition(active target: Bool, reduced: Bool) async {
        guard !Task.isCancelled, begin(active: target, reduced: reduced) else { return }
        if reduced {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        apply(active: target, reduced: reduced)
        if !reduced && target {
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            revealCanvas()
        }
    }

    func begin(active target: Bool, reduced: Bool) -> Bool {
        guard active != target else {
            visible = true
            canvasShown = target
            return false
        }
        if reduced { visible = false }
        return true
    }

    func apply(active target: Bool, reduced: Bool) {
        active = target
        visible = true
        canvasShown = reduced && target
    }

    func revealCanvas() { canvasShown = active }
}

public enum AssistantRail {
    public static func ordered(_ rows: [MeetingRow], cited: Set<MeetingID>) -> [MeetingRow] {
        rows.filter { cited.contains($0.id) } + rows.filter { !cited.contains($0.id) }
    }
}
