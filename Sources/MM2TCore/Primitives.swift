import Foundation

public struct MeetingID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try UUID(from: decoder) }
    public func encode(to encoder: Encoder) throws { try rawValue.encode(to: encoder) }
    public var description: String { rawValue.uuidString }
}

public struct PersonID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try UUID(from: decoder) }
    public func encode(to encoder: Encoder) throws { try rawValue.encode(to: encoder) }
    public var description: String { rawValue.uuidString }
}

/// Stable within one meeting. `.me` is the mic track; remote speakers are `r1`, `r2`, ...
public struct SpeakerID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try String(from: decoder) }
    public func encode(to encoder: Encoder) throws { try rawValue.encode(to: encoder) }
    public var description: String { rawValue }

    public static let me = SpeakerID("me")
    static func remote(_ index: Int) -> SpeakerID { SpeakerID("r\(index)") }
}

public struct UtteranceID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try String(from: decoder) }
    public func encode(to encoder: Encoder) throws { try rawValue.encode(to: encoder) }
    public var description: String { rawValue }
}

/// Seconds from the start of the recording.
public struct TimeRange: Hashable, Codable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        precondition(end >= start, "TimeRange end precedes start")
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end - start }

    public func overlap(with other: TimeRange) -> TimeInterval {
        max(0, min(end, other.end) - max(start, other.start))
    }

    public func intersects(_ other: TimeRange) -> Bool {
        start < other.end && other.start < end
    }

    public func distance(to other: TimeRange) -> TimeInterval {
        if intersects(other) { return 0 }
        return other.start >= end ? other.start - end : start - other.end
    }
}

public enum Track: String, Codable, Sendable, CaseIterable {
    case me
    case remote
}

/// A speaker embedding vector from the diarizer.
public struct Embedding: Hashable, Codable, Sendable {
    public let values: [Float]
    public init(_ values: [Float]) { self.values = values }
    public init(from decoder: Decoder) throws { values = try [Float](from: decoder) }
    public func encode(to encoder: Encoder) throws { try values.encode(to: encoder) }

    public func cosineSimilarity(to other: Embedding) -> Double {
        guard values.count == other.values.count, !values.isEmpty else { return 0 }
        var dot = 0.0, a = 0.0, b = 0.0
        for (x, y) in zip(values, other.values) {
            dot += Double(x) * Double(y)
            a += Double(x) * Double(x)
            b += Double(y) * Double(y)
        }
        guard a > 0, b > 0 else { return 0 }
        return dot / (a.squareRoot() * b.squareRoot())
    }
}

public struct TimedWord: Hashable, Codable, Sendable {
    public let text: String
    public let range: TimeRange
    public init(text: String, range: TimeRange) {
        self.text = text
        self.range = range
    }
    public init(_ text: String, _ start: TimeInterval, _ end: TimeInterval) {
        self.init(text: text, range: TimeRange(start: start, end: end))
    }
}

enum JSONFile {
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
