import Foundation
import MM2TCore
import OSLog

/// Translates one recording's captions on this Mac as they arrive. Every request, finished segment
/// or partial, goes to the translator one at a time in the order it was made, so segments are
/// translated in the order they settle. Of the unfinished partial only its settled part is
/// sent (`PartialTranslationPolicy`), at least 250 ms apart and one at a time; each result replaces
/// the shown translation in one step and nothing is blanked while the next is on its way. Results
/// land on their own segment by identity. A failure leaves the captions as they are and never
/// touches their status. Nothing here is saved.
@MainActor
final class LiveTranslation {
    private static let logger = Logger(subsystem: "dev.mm2t.app", category: "Captions")

    private weak var captions: LiveCaptions?
    private let translator: any CaptionTranslator
    private let source: CaptionLanguage?
    private let engine: CaptionEngine
    private let target: CaptionTarget
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    /// Requests waiting their turn, and the one running. One at a time: separate tasks calling the
    /// translator would reach it in whatever order the scheduler runs them, not the order they were made.
    private var queue: [@MainActor () async -> Void] = []
    private var running: Task<Void, Never>?
    /// What was last sent for the current partial, and when anything was last sent for one.
    private var partialSent: String?
    private var partialSentAt: Date?
    private var partialInFlight = false
    private var partialWait: Task<Void, Never>?
    private var hasLoggedFailure = false
    private var isStopped = false

    init(captions: LiveCaptions, translator: any CaptionTranslator, target: CaptionTarget, engine: CaptionEngine = .firefox, source: CaptionLanguage? = nil,
         now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.captions = captions
        self.translator = translator
        self.source = source
        self.engine = engine
        self.target = target
        self.now = now
        self.sleep = sleep
    }

    /// How the text reaches the target language; nil when it is already there or has no language.
    private func route(of text: String) -> CaptionRoute? {
        guard let language = CaptionLanguage.of(text) else { return nil }
        let route = target.route(from: source ?? language, engine: engine)
        return route == .none ? nil : route
    }

    func finished(_ segment: LiveCaptions.Segment) {
        guard !isStopped, let route = route(of: segment.text) else { return }
        captions?.willTranslate(segment.id)
        run { [weak self] in
            let result = await self?.translated(segment.text, along: route)
            self?.captions?.attach(result, to: segment.id)
        }
    }

    /// The partial settled into a segment: the next partial starts its own sends.
    func partialFinished() {
        partialSent = nil
        partialWait?.cancel()
        partialWait = nil
    }

    func partialChanged() {
        guard !isStopped, let captions else { return }
        guard PartialTranslationPolicy.stablePart(of: captions.partial, lastSent: partialSent) != nil else { return }
        schedulePartial()
    }

    func stop() {
        isStopped = true
        partialWait?.cancel()
        queue = []
        running?.cancel()
        running = nil
    }

    private func schedulePartial() {
        guard !partialInFlight, partialWait == nil else { return }
        let gap = PartialTranslationPolicy.minimumGap
        let wait = partialSentAt.map { gap - now().timeIntervalSince($0) } ?? 0
        guard wait > 0 else { return sendPartial() }
        partialWait = Task { [weak self, sleep] in
            do { try await sleep(.milliseconds(Int((wait * 1000).rounded(.up)))) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.partialWait = nil
            self.sendPartial()
        }
    }

    private func sendPartial() {
        guard !isStopped, let captions,
              let text = PartialTranslationPolicy.stablePart(of: captions.partial, lastSent: partialSent),
              let route = route(of: text) else { return }
        let id = captions.partialID
        partialSent = text
        partialSentAt = now()
        partialInFlight = true
        run { [weak self] in
            let result = await self?.translated(text, along: route)
            guard let self else { return }
            self.partialInFlight = false
            if let result { self.captions?.attachPartial(result, for: id) }
            // Words that settled while this one was out get their turn.
            self.partialChanged()
        }
    }

    /// Queues a request; it starts once every earlier one has finished.
    private func run(_ body: @escaping @MainActor () async -> Void) {
        queue.append(body)
        startNext()
    }

    private func startNext() {
        guard running == nil, !isStopped, !queue.isEmpty else { return }
        let body = queue.removeFirst()
        running = Task { [weak self] in
            await body()
            guard let self, !self.isStopped else { return }
            self.running = nil
            self.startNext()
        }
    }

    private func translated(_ text: String, along route: CaptionRoute) async -> String? {
        let output: String
        switch route {
        case .none:
            return nil
        case .simplify:
            // Simplified Chinese is asked for here and only here.
            output = TraditionalChinese.simplified(text)
        case .models(let languages):
            do {
                output = try await translator.translate(text, through: languages)
            } catch {
                if !hasLoggedFailure, !isStopped {
                    hasLoggedFailure = true
                    Self.logger.error("event=caption_translation_failed")
                }
                return nil
            }
        }
        guard !Task.isCancelled, !isStopped else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Only Traditional Chinese output is made Traditional; every other language stays as it came.
        return target == .traditionalChinese ? TraditionalChinese.convert(trimmed) : trimmed
    }
}
