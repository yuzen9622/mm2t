import Foundation

// MARK: Streaming transcription

/// What a streaming speech service says about the segment being spoken. A cloud service and a
/// self-hosted sliding-window model both fit: revisable text first, then the settled segment.
public enum StreamingTranscriptEvent: Hashable, Sendable {
    /// The unfinished segment so far; replaces the previous partial.
    case partial(String)
    /// The settled text of the segment; the next partial starts a new one.
    case final(String)
}

/// How a streaming session is opened.
public struct StreamingTranscriptionRequest: Hashable, Sendable {
    /// ISO 639-1; nil leaves detection to the service.
    public var languageCode: String?
    public var hints: [String]
    /// Mono 16-bit PCM at this rate is what `send` turns its samples into.
    public var sampleRate: Int
    /// The end of what was said before a reconnect, for services that take earlier text as context.
    public var previousText: String?

    public init(languageCode: String?, hints: [String], sampleRate: Int, previousText: String? = nil) {
        self.languageCode = languageCode
        self.hints = hints
        self.sampleRate = sampleRate
        self.previousText = previousText
    }
}

/// One open stream. `events` finishes when the service closes it and throws
/// `TranscriptionError.unreachable` for a failure worth reconnecting after, `.failed` for one that is not.
public protocol StreamingTranscriptionSession: Sendable {
    var events: AsyncThrowingStream<StreamingTranscriptEvent, Error> { get }
    /// Mono samples in -1...1 at the request's rate.
    func send(_ samples: [Float]) async throws
    func close() async
    /// The consumer has cleared its display and will discard all remaining events.
    func discard() async
}

public extension StreamingTranscriptionSession {
    func discard() async { await close() }
}

/// Opens streaming sessions. Its text is for display only and never becomes the record.
public protocol StreamingTranscriptionProvider: Sendable {
    /// Throws `.ineligible` to skip silently, `.unreachable` to try again later, or `.failed` to give up.
    func open(_ request: StreamingTranscriptionRequest) async throws -> any StreamingTranscriptionSession
    /// Releases recording-scoped resources or hands them to the saved meeting's transcription.
    func stop(retainingLeaseFor meeting: MeetingID?) async
}

public enum StreamingTranscriptionAvailability: Error {
    case ineligible
}

public extension StreamingTranscriptionProvider {
    func stop(retainingLeaseFor meeting: MeetingID?) async {}
}
