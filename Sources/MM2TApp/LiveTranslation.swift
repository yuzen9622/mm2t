import Foundation
import MM2TCore
import OSLog

/// Translates one recording's captions on this Mac as they arrive. Finished segments are sent to
/// the translator in the order they settle. Of the unfinished partial only its settled part is
/// sent (`PartialTranslationPolicy`), at least 250 ms apart and one at a time; each result replaces
/// the shown translation in one step and nothing is blanked while the next is on its way. Results
/// land on their own segment by identity. A failure leaves the captions as they are and never
/// touches their status. Nothing here is saved.
@MainActor
final class LiveTranslation {
    private static let logger = Logger(subsystem: "dev.mm2t.app", category: "Captions")

    private weak var captions: LiveCaptions?
    private let translator: any CaptionTranslator
    private let target: CaptionLanguage
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    private var work: [Int: Task<Void, Never>] = [:]
    private var nextWork = 0
    /// What was last sent for the current partial, and when anything was last sent for one.
    private var partialSent: String?
    private var partialSentAt: Date?
    private var partialInFlight = false
    private var partialWait: Task<Void, Never>?
    private var hasLoggedFailure = false
    private var isStopped = false

    init(captions: LiveCaptions, translator: any CaptionTranslator, target: CaptionLanguage,
         now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.captions = captions
        self.translator = translator
        self.target = target
        self.now = now
        self.sleep = sleep
    }

    private func source(of text: String) -> CaptionLanguage? {
        guard let language = CaptionLanguage.of(text), language != target else { return nil }
        return language
    }

    func finished(_ segment: LiveCaptions.Segment) {
        guard !isStopped, let source = source(of: segment.text) else { return }
        captions?.willTranslate(segment.id)
        run { [weak self] in
            let result = await self?.translated(segment.text, from: source)
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
        for task in work.values { task.cancel() }
        work = [:]
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
              let source = source(of: text) else { return }
        let id = captions.partialID
        partialSent = text
        partialSentAt = now()
        partialInFlight = true
        run { [weak self] in
            let result = await self?.translated(text, from: source)
            guard let self else { return }
            self.partialInFlight = false
            if let result { self.captions?.attachPartial(result, for: id) }
            // Words that settled while this one was out get their turn.
            self.partialChanged()
        }
    }

    /// Started in arrival order on the main actor, so the translator receives them in that order.
    private func run(_ body: @escaping @MainActor () async -> Void) {
        let id = nextWork
        nextWork += 1
        work[id] = Task { [weak self] in
            await body()
            self?.work[id] = nil
        }
    }

    private func translated(_ text: String, from source: CaptionLanguage) async -> String? {
        do {
            let output = try await translator.translate(text, from: source, to: target)
            guard !Task.isCancelled, !isStopped else { return nil }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return target == .traditionalChinese ? TraditionalChinese.convert(trimmed) : trimmed
        } catch {
            if !hasLoggedFailure, !isStopped {
                hasLoggedFailure = true
                Self.logger.error("event=caption_translation_failed")
            }
            return nil
        }
    }
}
