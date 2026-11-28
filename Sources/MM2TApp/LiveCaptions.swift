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
    public private(set) var translationTarget: CaptionTarget?
    /// Segments whose final translation has been asked for and has not come back.
    public private(set) var awaitingTranslation: Set<Int> = []
    /// The latest translation of the unfinished partial's settled part. It stays on screen while
    /// the partial grows and is replaced only by a newer one; it is never blanked.
    public private(set) var partialTranslation: String?
    /// What a finished segment shows until its own translation arrives: the last translation of
    /// it while it was still a partial. Kept after a failure, so a shown translation never goes away.
    public private(set) var provisionalTranslations: [Int: String] = [:]

    @ObservationIgnored var onFinalized: ((Segment) -> Void)?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var partialStarted: Date?
    @ObservationIgnored private var fixedTranslationSource: CaptionLanguage?
    @ObservationIgnored private var translation: LiveTranslation?
    @ObservationIgnored private var translationRevision = UUID()
    public internal(set) var translationSession: MeetingID?
    @ObservationIgnored var translationOverride: Bool?
    public private(set) var preparingTranslation = false

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
        let carried = partialTranslation
        partial = ""
        partialStarted = nil
        partialTranslation = nil
        translation?.partialFinished()
        guard !text.isEmpty else { return }
        let segment = Segment(id: nextID, text: text, started: started, ended: time)
        segments.append(segment)
        if let carried, needsTranslation(text) { provisionalTranslations[segment.id] = carried }
        nextID += 1
        if segments.count > Self.limit {
            segments.removeFirst(segments.count - Self.limit)
            let kept = Set(segments.map(\.id))
            awaitingTranslation.formIntersection(kept)
            provisionalTranslations = provisionalTranslations.filter { kept.contains($0.key) }
        }
        translation?.finished(segment)
        onFinalized?(segment)
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
        translationSession = nil
        translationOverride = nil
        resetTranslation()
    }

    // MARK: Translation

    private func resetTranslation() {
        translationRevision = UUID()
        preparingTranslation = false
        translation?.stop()
        translation = nil
        fixedTranslationSource = nil
        translationTarget = nil
        awaitingTranslation = []
        partialTranslation = nil
        provisionalTranslations = [:]
        for index in segments.indices where segments[index].translation != nil { segments[index].translation = nil }
    }

    /// Resolve just the translator. The audio stream and the caption segment identities stay live.
    func configureTranslation(settings: AppSettings, catalog: any ProviderCatalog, prepare: () async -> Void = {}) async {
        resetTranslation()
        let revision = translationRevision
        let target = settings.captionTranslation.target
        let wantsTranslation = translationSession != nil && (translationOverride ?? settings.translationEnabled) && target != nil
        preparingTranslation = wantsTranslation
        await prepare()
        guard revision == translationRevision else { return }
        defer { if revision == translationRevision { preparingTranslation = false } }
        guard wantsTranslation, let target else { return }
        let engine = settings.captionEngine
        let source = engine == .apple ? settings.transcriptionLanguage.fixedCaptionSource : nil
        guard let translator = await catalog.captionTranslator(for: target, engine: engine, source: source),
              revision == translationRevision, !Task.isCancelled else { return }
        translate(with: translator, to: target, engine: engine, source: source)
        translation?.partialChanged()
    }

    /// Translates this recording's captions into `target` from here on. The translation queue belongs to this target and engine.
    func translate(with translator: any CaptionTranslator, to target: CaptionTarget, engine: CaptionEngine = .firefox, source: CaptionLanguage? = nil,
                   sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        translation?.stop()
        fixedTranslationSource = source
        translationTarget = target
        translation = LiveTranslation(captions: self, translator: translator, target: target, engine: engine, source: source, now: now, sleep: sleep)
    }

    /// The id the unfinished partial will have once it settles.
    var partialID: Int { nextID }

    /// The text needs translating: translation is on and it is in the other language.
    func needsTranslation(_ text: String) -> Bool {
        guard let target = translationTarget, let language = CaptionLanguage.of(text) else { return false }
        return target.route(from: fixedTranslationSource ?? language) != .none
    }

    /// The translation a surface shows for a finished segment: its own, or until that arrives the
    /// one it had as a partial.
    public func shownTranslation(of segment: Segment) -> String? {
        segment.translation ?? provisionalTranslations[segment.id]
    }

    /// A segment's main text: its translation, its own words when none is needed or one failed
    /// before anything was shown, or nothing yet.
    public func mainText(of segment: Segment) -> String? {
        if let shown = shownTranslation(of: segment) { return shown }
        return awaitingTranslation.contains(segment.id) ? nil : segment.text
    }

    /// The same for the unfinished partial: its last translation, or its own words when it needs none.
    public var partialMainText: String {
        partialTranslation ?? (needsTranslation(partial) ? "" : partial)
    }

    /// Segments as a surface shows them as main text, leaving out those with nothing to show yet.
    public var displaySegments: [Segment] {
        segments.compactMap { segment in
            mainText(of: segment).map { Segment(id: segment.id, text: $0, started: segment.started, ended: segment.ended) }
        }
    }

    private func partialChanged() {
        translation?.partialChanged()
    }

    func willTranslate(_ id: Int) {
        if segments.contains(where: { $0.id == id }) { awaitingTranslation.insert(id) }
    }

    /// Attaches a final result to its own segment by identity, whatever order results come back in.
    /// A failure (nil) keeps whatever the segment already showed.
    func attach(_ text: String?, to id: Int) {
        awaitingTranslation.remove(id)
        guard let text, let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].translation = text
        provisionalTranslations[id] = nil
    }

    /// A translation of part of the partial that will become segment `id`. It replaces the shown
    /// one in one step; one arriving after its segment settled updates that segment's interim text.
    func attachPartial(_ text: String, for id: Int) {
        if id == nextID {
            partialTranslation = text
        } else if let segment = segments.first(where: { $0.id == id }), segment.translation == nil,
                  needsTranslation(segment.text) {
            provisionalTranslations[id] = text
        }
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
