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
        /// Its translation on this Mac, when live translation is on and it is not already in the
        /// target language.
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

    /// The language captions are translated into for this recording; nil when translation is off.
    public private(set) var translationTarget: CaptionLanguage?
    /// Segments whose translation has been asked for and has not come back. Until it does they
    /// show no main text on the bar; a failed one goes back to showing its own words.
    public private(set) var awaitingTranslation: Set<Int> = []
    /// The translation of exactly the current `partial`; nil the moment the partial changes.
    public private(set) var partialTranslation: String?
    /// The current partial needs a translation that has not arrived yet.
    public private(set) var isPartialAwaitingTranslation = false

    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var partialStarted: Date?
    @ObservationIgnored private var translation: LiveTranslation?

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
            partialChanged()
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
        partialChanged()
        guard !text.isEmpty else { return }
        let segment = Segment(id: nextID, text: text, started: started, ended: time)
        segments.append(segment)
        nextID += 1
        if segments.count > Self.limit {
            segments.removeFirst(segments.count - Self.limit)
            awaitingTranslation.formIntersection(segments.map(\.id))
        }
        translation?.finished(segment)
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
        translation?.stop()
        translation = nil
        translationTarget = nil
        awaitingTranslation = []
        partialTranslation = nil
        isPartialAwaitingTranslation = false
    }

    // MARK: Translation

    /// Translates this recording's captions into `target` from here on. Called once per recording,
    /// after `clear()`; the translator, and the model it holds, goes with the next `clear()`.
    func translate(with translator: any CaptionTranslator, to target: CaptionLanguage,
                   sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        translation?.stop()
        translationTarget = target
        translation = LiveTranslation(captions: self, translator: translator, target: target, now: now, sleep: sleep)
    }

    /// What a surface shows as a segment's main text: its translation, its own words when no
    /// translation is needed or one failed, or nothing while one is on its way.
    public func mainText(of segment: Segment) -> String? {
        if let translation = segment.translation { return translation }
        return awaitingTranslation.contains(segment.id) ? nil : segment.text
    }

    /// The same for the unfinished partial.
    public var partialMainText: String {
        partialTranslation ?? (isPartialAwaitingTranslation ? "" : partial)
    }

    private func partialChanged() {
        partialTranslation = nil
        isPartialAwaitingTranslation = translation?.needsTranslation(partial) ?? false
        translation?.partialChanged()
    }

    func willTranslate(_ id: Int) {
        if segments.contains(where: { $0.id == id }) { awaitingTranslation.insert(id) }
    }

    /// Attaches a result to its own segment by identity, whatever order results come back in.
    func attach(_ text: String?, to id: Int) {
        awaitingTranslation.remove(id)
        guard let text, let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].translation = text
    }

    /// Shown only while the partial is still exactly the text that was translated.
    func attachPartial(_ text: String?, for source: String) {
        guard source == partial, !partial.isEmpty else { return }
        partialTranslation = text
        isPartialAwaitingTranslation = false
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
