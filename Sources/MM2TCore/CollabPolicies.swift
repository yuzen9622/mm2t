import Foundation

public struct CollabSuggestion: Decodable, Equatable, Sendable {
    public let kind: CollabComponentKind
    public let title: String
    public let instruction: String

    private enum Key: String, CodingKey { case kind, title, instruction }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        kind = try c.decode(CollabComponentKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title).trimmingCharacters(in: .whitespacesAndNewlines)
        instruction = try c.decode(String.self, forKey: .instruction).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 24, !instruction.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .title, in: c, debugDescription: "Invalid suggestion")
        }
    }
}

public struct SuggestionPolicy: Sendable {
    public struct Card: Sendable {
        private var remaining: TimeInterval = 15
        private var resumed: Date?
        public init(now: Date) { resumed = now }
        public func timeLeft(at now: Date) -> TimeInterval {
            max(0, remaining - (resumed.map { now.timeIntervalSince($0) } ?? 0))
        }
        public func progress(at now: Date) -> Double { min(1, timeLeft(at: now) / 15) }
        public mutating func hover(_ hovering: Bool, now: Date) {
            if hovering, resumed != nil { remaining = timeLeft(at: now); resumed = nil }
            if !hovering, resumed == nil { resumed = now }
        }
    }

    private var lastAsked: Date
    private var lastClosed: Date?
    private var characters = 0
    private var history: [CollabComponentKind: Set<String>] = [:]
    public var titles: Set<String> { Set(history.values.joined()) }

    public init(now: Date) { lastAsked = now }

    public mutating func record(_ count: Int) { characters += count }

    public func canAsk(now: Date, captionsOn: Bool, cardVisible: Bool) -> Bool {
        captionsOn && !cardVisible && characters >= 40 && now.timeIntervalSince(lastAsked) >= 20
            && (lastClosed.map { now.timeIntervalSince($0) >= 60 } ?? true)
    }

    public mutating func shouldAsk(now: Date, captionsOn: Bool, cardVisible: Bool) -> Bool {
        guard canAsk(now: now, captionsOn: captionsOn, cardVisible: cardVisible) else { return false }
        lastAsked = now
        characters = 0
        return true
    }

    public mutating func remember(kind: CollabComponentKind, title: String) {
        let key = Self.normalize(title)
        if !key.isEmpty { history[kind, default: []].insert(key) }
    }

    public mutating func offer(kind: CollabComponentKind, title: String) -> Bool {
        let key = Self.normalize(title)
        guard !key.isEmpty, !history[kind, default: []].contains(where: { Self.similar($0, key) }) else { return false }
        history[kind, default: []].insert(key)
        return true
    }

    private static func similar(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.contains(rhs) || rhs.contains(lhs) { return true }
        func bigrams(_ text: String) -> Set<String> {
            Set(zip(text, text.dropFirst()).map { String([$0, $1]) })
        }
        let left = bigrams(lhs), right = bigrams(rhs)
        let total = left.union(right).count
        return total > 0 && 5 * left.intersection(right).count >= 3 * total
    }

    public mutating func closed(at now: Date) { lastClosed = now }

    public static func normalize(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public enum LiveUpdatePolicy {
    public struct Candidate: Sendable {
        public let id: String
        public let kind: CollabComponentKind
        public let lastUpdated: Date
        public let newCharacters: Int

        public init(id: String, kind: CollabComponentKind, lastUpdated: Date, newCharacters: Int) {
            self.id = id
            self.kind = kind
            self.lastUpdated = lastUpdated
            self.newCharacters = newCharacters
        }
    }

    public static func next(_ candidates: [Candidate], now: Date, inFlight: Bool) -> String? {
        guard !inFlight else { return nil }
        return candidates.filter {
            $0.kind.updatesLive && $0.newCharacters >= 200 && now.timeIntervalSince($0.lastUpdated) >= 90
        }.min { ($0.lastUpdated, $0.id) < ($1.lastUpdated, $1.id) }?.id
    }
}
