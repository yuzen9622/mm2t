import Foundation

/// An API key or token. Printing, interpolating or dumping it never shows the value,
/// so a provider or request that holds one can be logged safely.
public struct Secret: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable, ExpressibleByStringLiteral
{
    public let revealed: String

    public init(_ value: String) { revealed = value.trimmingCharacters(in: .whitespacesAndNewlines) }
    public init(stringLiteral value: String) { self.init(value) }

    public var isEmpty: Bool { revealed.isEmpty }
    public var description: String { "Secret(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
