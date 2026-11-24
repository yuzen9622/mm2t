import Foundation
import MM2TCore
import OSLog

/// Streams the recording's mixed audio to a streaming speech service and hands what comes back to
/// `LiveCaptions`. Runs beside the recording and never touches it: a failure here only changes the
/// caption status. Audio that arrives while no session is open is dropped, not replayed.
public actor CaptionStream {
    private static let logger = Logger(subsystem: "dev.mm2t.app", category: "Captions")
    /// Waits before each reconnect in a row; the last repeats.
    static let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10)]
    /// Audio leaves in chunks of 100 to 250 ms.
    static let minimumChunk: TimeInterval = 0.1
    static let maximumChunk: TimeInterval = 0.25

    private let provider: any StreamingTranscriptionProvider
    private let languageCode: String?
    private let hints: [String]
    private let captions: LiveCaptions
    private let sleep: @Sendable (Duration) async throws -> Void
    private let retainHostedLease: @MainActor @Sendable () -> Bool

    private var sampleRate = 16_000
    private var audioTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var connection: (any StreamingTranscriptionSession)?
    /// Bumped by every pause, resume and stop, so a session opened for an earlier one is closed unused.
    private var generation = 0
    private var isPaused = false
    private var isStopped = false
    private var failures = 0
    private var pending: [Float] = []

    public init(provider: any StreamingTranscriptionProvider, languageCode: String?, hints: [String],
                captions: LiveCaptions, retainHostedLease: @escaping @MainActor @Sendable () -> Bool = { false },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.provider = provider
        self.languageCode = languageCode
        self.hints = hints
        self.captions = captions
        self.sleep = sleep
        self.retainHostedLease = retainHostedLease
    }

    /// Starts reading `audio` (mono samples at `sampleRate`) and opens the first session.
    public func start(audio: AsyncStream<[Float]>, sampleRate: Int) async {
        guard !isStopped, audioTask == nil else { return }
        self.sampleRate = sampleRate
        await captions.set(.connecting)
        guard !isStopped else { return }
        audioTask = Task { [weak self] in
            for await samples in audio {
                await self?.feed(samples)
            }
        }
        connect()
    }

    /// The recording paused: the session closes, since every second streamed is billed.
    public func pause() async {
        guard !isStopped, !isPaused else { return }
        isPaused = true
        await disconnect()
        guard !isStopped else { return }
        await captions.settlePartial()
    }

    public func resume() async {
        guard !isStopped, isPaused else { return }
        isPaused = false
        failures = 0
        await captions.set(.connecting)
        guard !isStopped else { return }
        connect()
    }

    /// The recording stopped: the session closes and every caption is cleared.
    public func stop(retainingLeaseFor savedMeeting: MeetingID? = nil) async {
        guard !isStopped else { return }
        isStopped = true
        audioTask?.cancel()
        audioTask = nil
        let open = disconnectSession()
        await captions.clear()
        let meeting = await retainHostedLease() ? savedMeeting : nil
        if let open { Task { await open.discard() } }
        await provider.stop(retainingLeaseFor: meeting)
    }

    // MARK: Session

    private func connect() {
        generation += 1
        let current = generation
        runTask?.cancel()
        runTask = Task { [weak self] in await self?.run(current) }
    }

    private func disconnect() async {
        await disconnectSession()?.close()
    }

    private func disconnectSession() -> (any StreamingTranscriptionSession)? {
        generation += 1
        runTask?.cancel()
        runTask = nil
        pending = []
        defer { connection = nil }
        return connection
    }

    private func isCurrent(_ run: Int) -> Bool {
        run == generation && !isPaused && !isStopped && !Task.isCancelled
    }

    /// Opens sessions until one fails for a reason a new session cannot fix, or the run is superseded.
    private func run(_ run: Int) async {
        while isCurrent(run) {
            if failures > 0 {
                do { try await sleep(Self.backoff[min(failures, Self.backoff.count) - 1]) } catch { return }
                guard isCurrent(run) else { return }
            }
            do {
                let previous = await captions.segments.last?.text
                let session = try await provider.open(StreamingTranscriptionRequest(
                    languageCode: languageCode, hints: hints, sampleRate: sampleRate, previousText: previous))
                guard isCurrent(run) else {
                    if isStopped { await session.discard() } else { await session.close() }
                    return
                }
                connection = session
                pending = []
                await captions.set(.live)
                for try await event in session.events {
                    guard isCurrent(run) else { return }
                    failures = 0
                    await captions.receive(event)
                }
                Self.logger.info("event=captions_session_closed")
            } catch StreamingTranscriptionAvailability.ineligible {
                guard isCurrent(run) else { return }
                await captions.set(.off)
                return
            } catch TranscriptionError.failed(let reason) {
                guard isCurrent(run) else { return }
                Self.logger.error("event=captions_unavailable")
                await disconnect()
                guard !isStopped else { return }
                await captions.set(.unavailable(reason))
                return
            } catch {
                guard isCurrent(run) else { return }
                Self.logger.info("event=captions_session_failed")
            }
            guard isCurrent(run) else { return }
            let lost = connection
            connection = nil
            pending = []
            await lost?.close()
            guard isCurrent(run) else { return }
            failures += 1
            await captions.set(.reconnecting)
        }
    }

    // MARK: Audio

    private func feed(_ samples: [Float]) async {
        guard let connection, !isPaused, !isStopped else {
            pending = []
            return
        }
        pending += samples
        let minimum = Int(Double(sampleRate) * Self.minimumChunk)
        let maximum = Int(Double(sampleRate) * Self.maximumChunk)
        while pending.count >= minimum {
            let chunk = Array(pending.prefix(maximum))
            pending.removeFirst(chunk.count)
            do {
                try await connection.send(chunk)
            } catch {
                // Closing ends the session's events, and the run loop reconnects.
                pending = []
                await connection.close()
                return
            }
        }
    }
}
