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

    /// Why a suggestion is being asked for now.
    public struct Ask: Equatable, Sendable {
        /// The kinds someone named in the captions since the last ask.
        public let requested: Set<CollabComponentKind>
        /// Enough talk and time have passed for an unprompted look at the meeting.
        public let passive: Bool

        public init(requested: Set<CollabComponentKind>, passive: Bool) {
            self.requested = requested
            self.passive = passive
        }
    }

    /// An unprompted look needs this much new caption text and this long since the last ask.
    static let passiveCharacters = 300
    static let passiveInterval: TimeInterval = 120
    /// A named kind is looked at this soon after the last ask.
    static let requestInterval: TimeInterval = 15
    /// After a card is closed, unprompted looks wait this long.
    static let closedInterval: TimeInterval = 60
    /// A kind already offered is not offered again unprompted for this long.
    static let kindCooldown: TimeInterval = 600

    private var lastAsked: Date
    private var lastClosed: Date?
    private var characters = 0
    private var requested: Set<CollabComponentKind> = []
    private var offeredAt: [CollabComponentKind: Date] = [:]
    private var history: [CollabComponentKind: Set<String>] = [:]
    /// What was offered, in order, so the model knows what it already proposed.
    public private(set) var offered: [(kind: CollabComponentKind, title: String)] = []

    public init(now: Date) { lastAsked = now }

    public mutating func record(_ text: String) {
        characters += text.count
        requested.formUnion(CollabComponentKind.requested(in: text))
    }

    public func canAsk(now: Date, captionsOn: Bool, cardVisible: Bool) -> Bool {
        ask(now: now, captionsOn: captionsOn, cardVisible: cardVisible) != nil
    }

    public mutating func shouldAsk(now: Date, captionsOn: Bool, cardVisible: Bool) -> Ask? {
        guard let ask = ask(now: now, captionsOn: captionsOn, cardVisible: cardVisible) else { return nil }
        lastAsked = now
        characters = 0
        requested = []
        return ask
    }

    private func ask(now: Date, captionsOn: Bool, cardVisible: Bool) -> Ask? {
        guard captionsOn, !cardVisible else { return nil }
        let since = now.timeIntervalSince(lastAsked)
        let passive = characters >= Self.passiveCharacters && since >= Self.passiveInterval
            && (lastClosed.map { now.timeIntervalSince($0) >= Self.closedInterval } ?? true)
        let named = since >= Self.requestInterval ? requested : []
        return passive || !named.isEmpty ? Ask(requested: named, passive: passive) : nil
    }

    /// The kinds this ask may suggest. Named kinds always may. An unprompted look leaves out kinds
    /// offered recently and live-updating kinds the room already has, which keep updating instead.
    public func kinds(for ask: Ask, existing: Set<CollabComponentKind>, now: Date) -> Set<CollabComponentKind> {
        guard ask.passive else { return ask.requested }
        let open = CollabComponentKind.suggestible.filter { kind in
            !(kind.updatesLive && existing.contains(kind))
                && (offeredAt[kind].map { now.timeIntervalSince($0) >= Self.kindCooldown } ?? true)
        }
        return ask.requested.union(open)
    }

    public mutating func remember(kind: CollabComponentKind, title: String) {
        let key = Self.normalize(title)
        if !key.isEmpty { history[kind, default: []].insert(key) }
    }

    public mutating func offer(kind: CollabComponentKind, title: String, now: Date) -> Bool {
        let key = Self.normalize(title)
        guard !key.isEmpty, !history[kind, default: []].contains(where: { Self.similar($0, key) }) else { return false }
        history[kind, default: []].insert(key)
        offeredAt[kind] = now
        offered.append((kind, title))
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
