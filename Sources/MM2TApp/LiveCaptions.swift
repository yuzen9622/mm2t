import Foundation
import MM2TCore
import Observation

/// What the caption bar and the live page show while a recording runs. Display only: none of it
/// is saved, and the transcript of record still comes from the recording after the meeting.
@MainActor @Observable
public final class LiveCaptions {
    public enum Status: Equatable, Sendable {
        case off
        case connecting
        case live
        case reconnecting
        /// Captions stopped for this recording and will not come back without the user; the reason is shown once.
        case unavailable(String)
    }

    public struct Segment: Identifiable, Equatable, Sendable {
        public let id: Int
        public let text: String
        /// When its first words appeared and when it was settled, to group close segments into paragraphs.
        public let started: Date
        public let ended: Date
        /// Phase 2 fills this; nothing sets it yet.
        public var translation: String?
    }

    /// Finished segments older than this many are dropped.
    public static let limit = 200
    /// Segments that follow each other more closely than this read as one paragraph.
    public static let paragraphGap: TimeInterval = 2

    public private(set) var segments: [Segment] = []
    /// The unfinished segment, replaced as the service revises it.
    public private(set) var partial = ""
    public private(set) var status: Status = .off
    /// When text last changed; the bar dims after a long quiet stretch.
    public private(set) var lastActivity: Date?
    /// The bar was hidden by the user for this recording.
    public var isBarHidden = false

    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var partialStarted: Date?

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// Whether a caption surface has anything to do: captions run for this recording.
    public var isActive: Bool { status != .off }

    func receive(_ event: StreamingTranscriptEvent) {
        let time = now()
        switch event {
        case .partial(let text):
            let text = TraditionalChinese.convert(text)
            guard text != partial else { return }
            if partial.isEmpty, !text.isEmpty { partialStarted = time }
            partial = text
            lastActivity = time
        case .final(let text):
            append(TraditionalChinese.convert(text), at: time)
            lastActivity = time
        }
        if status == .connecting || status == .reconnecting { status = .live }
    }

    private func append(_ text: String, at time: Date) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let started = partialStarted ?? time
        partial = ""
        partialStarted = nil
        guard !text.isEmpty else { return }
        segments.append(Segment(id: nextID, text: text, started: started, ended: time))
        nextID += 1
        if segments.count > Self.limit { segments.removeFirst(segments.count - Self.limit) }
    }

    /// A session ended mid-segment: its unfinished words stay as they were last heard, since the
    /// next session will not hear that audio again.
    func settlePartial() {
        guard !partial.isEmpty else { return }
        append(partial, at: now())
    }

    func set(_ status: Status) {
        if status == .reconnecting { settlePartial() }
        self.status = status
    }

    /// The recording stopped: everything goes.
    func clear() {
        segments = []
        partial = ""
        partialStarted = nil
        status = .off
        lastActivity = nil
        isBarHidden = false
    }

    /// The text the live page shows as paragraphs: consecutive segments less than `paragraphGap` apart join.
    public var paragraphs: [[Segment]] {
        var result: [[Segment]] = []
        for segment in segments {
            if let previous = result.last?.last, segment.started.timeIntervalSince(previous.ended) < Self.paragraphGap {
                result[result.count - 1].append(segment)
            } else {
                result.append([segment])
            }
        }
        return result
    }
}
