import Foundation
import MM2TLocal
import MM2TCore
import MM2TSystem
import OSLog

/// Transcribes a recording while it is still being made, half a minute at a time, so that when the
/// meeting ends only its last stretch is left to send. Speech recognition is the one step whose wait
/// grows with the meeting's length; this takes it out of the wait after the meeting.
///
/// Pieces are transcribed without speaker labels, which a service numbers per file and so cannot be
/// joined across pieces; the on-device model separates the speakers afterwards. A failed piece is
/// retried at the end without discarding earlier pieces; a second failure falls back to the whole file.
public actor LiveTranscriber {
    private static let logger = Logger(subsystem: "dev.mm2t.app", category: "Transcription")
    /// Length of a piece. Shorter means less left at the end and more requests.
    public static let pieceSeconds: TimeInterval = 30
    static let breezePieceSeconds: TimeInterval = 4
    /// Breeze decodes a Whisper window of up to 30 s. Catch up using full windows and
    /// finish a short backlog in one pass. At the live edge, keep the final tail short.
    static func breezeWindow(remaining: TimeInterval, finishing: Bool) -> TimeInterval {
        if finishing || remaining >= 30 { return 30 }
        return remaining >= 12 ? 10 : breezePieceSeconds
    }
    /// How far back from a piece's end to look for a quiet place to cut.
    static let searchSeconds: TimeInterval = 10

    /// Hosted recording stops at the first local preference. Local-first Breeze has its own recording path.
    static func recordingChain(_ chain: TranscriptionChain) -> TranscriptionChain? {
        let hosted = Array(chain.routes.prefix { $0.source != .local })
        return hosted.isEmpty ? nil : TranscriptionChain(hosted)
    }

    private var mic: URL
    private var remote: URL
    private let chain: TranscriptionChain
    private let hints: [String]
    private let pieceSeconds: TimeInterval
    private let scratch: URL
    private let now: @Sendable () -> Date
    public let processing: LiveRecordingProcessor?
    private let configurationIsCurrent: @MainActor @Sendable () -> Bool
    private var invalidated = false

    private var cut = 0
    private var words: [Track: [TimedWord]] = [.me: [], .remote: []]
    private var sources: [Track: TranscriptionSource] = [:]
    private var failed = false
    private var consecutiveFailures = 0
    private var retryAfter: Date?
    private var isFinishing = false
    private var working: Task<Void, Never>?

    /// `mic` and `remote` are the files the recorder is writing. `scratch` holds each piece while it uploads.
    public init(mic: URL, remote: URL, chain: TranscriptionChain, hints: [String], scratch: URL,
                pieceSeconds: TimeInterval = LiveTranscriber.pieceSeconds, now: @escaping @Sendable () -> Date = Date.init,
                processing: LiveRecordingProcessor? = nil,
                configurationIsCurrent: @escaping @MainActor @Sendable () -> Bool = { true }) {
        self.mic = mic
        self.remote = remote
        self.chain = chain
        self.hints = hints
        self.scratch = scratch
        self.pieceSeconds = pieceSeconds
        self.now = now
        self.processing = processing
        self.configurationIsCurrent = configurationIsCurrent
    }

    /// Seconds of the recording transcribed so far.
    public private(set) var transcribedSeconds: TimeInterval = 0

    /// Transcribes every whole piece the recording has grown past. Call it now and then while recording;
    /// a call made while an earlier one is still working waits for it rather than starting a second.
    var pollingInterval: Duration { chain.routes.first?.source == .local ? .milliseconds(200) : .seconds(2) }

    public func advance() async {
        guard !isFinishing, await isConfigurationCurrent() else { return }
        if let retryAfter, now() < retryAfter { return }
        failed = false
        await run { await self.transcribePieces(final: false) }
    }

    /// Stops reading new pieces and lets the current upload finish before the recorder's files
    /// move into the library. Otherwise an in-flight advance can read an old path after the move
    /// and discard all the work done during the meeting.
    public func prepareForMove() async {
        isFinishing = true
        await processing?.stopCheckpoints()
        // MLX has already copied both WAV slices into memory before it waits for its helper.
        // The finalizer can join that work after the recorder publishes the durable audio.
        if !(chain.routes.first?.provider is BreezeMLX && processing == nil) { await working?.value }
    }

    /// Transcribes what is left once the recorder has closed the files, which by then have moved to
    /// `mic` and `remote` in the library. nil when a piece still fails or no word was heard.
    public func finish(mic: URL, remote: URL) async -> Transcription? {
        let started = ContinuousClock.now
        await prepareForMove()
        let active = working
        await withTaskCancellationHandler {
            await active?.value
        } onCancel: { active?.cancel() }
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard !Task.isCancelled else { await processing?.discard(); return nil }
        self.mic = mic
        self.remote = remote
        guard await isConfigurationCurrent() else {
            return nil
        }
        // A temporary network failure leaves `cut` at the last fully successful pair of tracks.
        // Retry that piece rather than sending the whole meeting again.
        failed = false
        await run { await self.transcribePieces(final: true) }
        guard !Task.isCancelled, await isConfigurationCurrent() else { await processing?.discard(); return nil }
        await processing?.finish()
        guard await isConfigurationCurrent() else { return nil }
        // Nothing heard at all is more likely this class judging quiet speech silent than a meeting
        // without a word, so that case is left to the whole-file transcription too.
        guard !failed, let fallback = chain.routes.first?.source,
              !(words[.me]!.isEmpty && words[.remote]!.isEmpty) else {
            Self.logger.notice("event=live_finish result=whole_file_fallback elapsed_seconds=\(Self.seconds(since: started), privacy: .public) completed_audio_seconds=\(self.transcribedSeconds, privacy: .public)")
            return nil
        }
        Self.logger.info("event=live_finish result=reused elapsed_seconds=\(Self.seconds(since: started), privacy: .public) completed_audio_seconds=\(self.transcribedSeconds, privacy: .public)")
        return Transcription(
            me: TrackTranscript(source: sources[.me] ?? fallback, content: .unlabeled(words[.me]!)),
            remote: TrackTranscript(source: sources[.remote] ?? fallback, content: .unlabeled(words[.remote]!)))
    }

    public func isConfigurationCurrent() async -> Bool {
        let current = await configurationIsCurrent()
        if !invalidated, current { return true }
        invalidated = true
        await processing?.discard()
        return false
    }

    public func progress() async -> LiveProcessingProgress {
        if let processing { return await processing.progress(transcribedSeconds: transcribedSeconds) }
        return LiveProcessingProgress(transcribedSeconds: transcribedSeconds, diarizedSeconds: 0,
            checkpointSeconds: 0, checkpointBusy: false, recordingProcessingEnabled: false)
    }

    private var currentTranscription: Transcription? {
        guard let fallback = chain.routes.first?.source else { return nil }
        return Transcription(
            me: TrackTranscript(source: sources[.me] ?? fallback, content: .unlabeled(words[.me]!)),
            remote: TrackTranscript(source: sources[.remote] ?? fallback, content: .unlabeled(words[.remote]!)))
    }

    private func run(_ work: @escaping @Sendable () async -> Void) async {
        let previous = working
        let task = Task {
            await previous?.value
            await work()
        }
        working = task
        if isFinishing {
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        } else {
            await task.value
        }
    }

    private func transcribePieces(final: Bool) async {
        while !Task.isCancelled, !failed, final || !isFinishing {
            guard await isConfigurationCurrent() else { failed = true; return }
            guard final || !isFinishing else { return }
            do {
                let available = min(try WAVFormat.frameCount(mic), try WAVFormat.frameCount(remote))
                let rate = try WAVFormat.read(mic, frames: 0..<1).sampleRate
                let remaining = Double(available - cut) / Double(rate)
                let mlx = chain.routes.first?.provider is BreezeMLX
                let seconds = mlx ? 30 : chain.routes.first?.source == .local
                    ? Self.breezeWindow(remaining: remaining, finishing: final) : pieceSeconds
                let piece = max(1, Int(seconds * Double(rate)))
                let search = min(piece / 2, Int(Self.searchSeconds * Double(rate)))
                var end = available
                if !final || available - cut > piece {
                    guard available - cut >= piece else { return }
                    // End the piece where both tracks are quietest, so no word is cut in half.
                    if mlx {
                        end = cut + piece
                    } else {
                        let from = cut + piece - search
                        let tail = (try WAVFormat.read(mic, frames: from..<cut + piece), try WAVFormat.read(remote, frames: from..<cut + piece))
                        end = from + QuietCut.index(mic: tail.0.samples, remote: tail.1.samples, window: rate * 3 / 10)
                        // Keep profile frames on one global timeline. Otherwise each piece's
                        // partial 50 ms tail adds another frame and accumulated echo stats drift.
                        let grid = max(1, Int(EchoCanceller.profileFrame * Double(rate)))
                        end = max((cut / grid + 1) * grid, ((end + grid / 2) / grid) * grid)
                        guard end <= available else { return }
                    }
                }
                guard end > cut else { return }
                let range = cut..<end
                let started = ContinuousClock.now
                let (a, b) = try await transcribePair(range, rate: rate)
                guard await isConfigurationCurrent() else { failed = true; return }
                for (track, result) in [(Track.me, a), (.remote, b)] {
                    words[track]! += result.words
                    if let source = result.source { sources[track] = source }
                }
                await processing?.append(mic: mic, remote: remote, range: range)
                cut = end
                transcribedSeconds = Double(end) / Double(rate)
                consecutiveFailures = 0
                retryAfter = nil
                Self.logger.info("event=live_piece elapsed_seconds=\(Self.seconds(since: started), privacy: .public) audio_seconds=\(Double(range.count) / Double(rate), privacy: .public)")
                if let processing, !final, await isConfigurationCurrent(), !isFinishing, let transcript = currentTranscription,
                   let manifest = try? RecordingManifest.read(from: mic.deletingLastPathComponent()) {
                    await processing.checkpoint(transcript, manifest: manifest)
                }
                if final, end == available { return }
            } catch {
                failed = true
                consecutiveFailures += 1
                let delay = min(120.0, 30.0 * pow(2, Double(min(consecutiveFailures - 1, 2))))
                retryAfter = now().addingTimeInterval(delay)
                Self.logger.notice("event=live_piece_failed retry_after_seconds=\(delay, privacy: .public) completed_audio_seconds=\(self.transcribedSeconds, privacy: .public)")
            }
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    private typealias Piece = (words: [TimedWord], source: TranscriptionSource?)

    private func transcribePair(_ range: Range<Int>, rate: Int) async throws -> (Piece, Piece) {
        guard rate == 16_000, chain.routes.count == 1, chain.routes[0].source == .local,
              let breeze = chain.routes[0].provider as? any TrackTranscriber else {
            async let mine = transcribe(.me, mic, range, rate, echoOf: remote)
            async let theirs = transcribe(.remote, remote, range, rate)
            return try await (mine, theirs)
        }
        let mine = try WAVFormat.read(mic, frames: range).samples
        let theirs = try WAVFormat.read(remote, frames: range).samples
        let cleaned = QuietCut.isSilent(mine) ? nil : EchoCanceller.clean(mic: mine, remote: theirs, sampleRate: rate)
        let channels = [cleaned?.samples ?? mine, theirs]
        let active = channels.indices.filter { !QuietCut.isSilent(channels[$0]) }
        let pcm = active.map { channels[$0].map { Float($0) / 32768 } }
        let results = try await breeze.transcribeTracks(pcm, hints: hints)
        var pieces = [Piece](repeating: ([], nil), count: 2)
        let offset = Double(range.lowerBound) / Double(rate)
        for (channel, words) in zip(active, results) {
            pieces[channel] = (words.filter { channel != 0 || cleaned?.echo.isEcho($0.range) != true }.map {
                TimedWord(text: $0.text, range: TimeRange(start: $0.range.start + offset, end: $0.range.end + offset))
            }, .local)
        }
        return (pieces[0], pieces[1])
    }

    /// The words of one piece of one track, timed from the start of the recording. The mic's piece
    /// first loses the speakers' echo of the remote one, and then the words that were only that echo.
    private nonisolated func transcribe(_ track: Track, _ url: URL, _ range: Range<Int>, _ rate: Int, echoOf played: URL? = nil) async throws
        -> (words: [TimedWord], source: TranscriptionSource?) {
        var audio = try WAVFormat.read(url, frames: range)
        if QuietCut.isSilent(audio.samples) { return ([], nil) }
        var echo: EchoProfile?
        if let played, let cleaned = EchoCanceller.clean(
            mic: audio.samples, remote: try WAVFormat.read(played, frames: range).samples, sampleRate: rate) {
            audio = WAVAudio(sampleRate: rate, samples: cleaned.samples)
            echo = cleaned.echo
        }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let file = scratch.appending(path: "\(track.rawValue)-\(range.lowerBound).wav")
        try WAVFormat.write(audio, to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transcript = try await chain.transcribe(audio: file, hints: hints, labelSpeakers: false)
        let offset = Double(range.lowerBound) / Double(rate)
        let words = transcript.words.filter { echo?.isEcho($0.range) != true }.map {
            TimedWord(text: $0.text, range: TimeRange(start: $0.range.start + offset, end: $0.range.end + offset))
        }
        Self.logger.info("event=live_track track=\(track.rawValue, privacy: .public) source=\(transcript.source.rawValue, privacy: .public) start_seconds=\(offset, privacy: .public) audio_seconds=\(Double(range.count) / Double(rate), privacy: .public) words=\(words.count, privacy: .public)")
        return (words, transcript.source)
    }
}
