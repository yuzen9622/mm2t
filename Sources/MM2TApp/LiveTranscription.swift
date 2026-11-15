import Foundation
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
    /// How far back from a piece's end to look for a quiet place to cut.
    static let searchSeconds: TimeInterval = 10

    /// Uses only the hosted routes before the first on-device route. Local-first stays offline
    /// while recording; a local fallback remains available to the full pipeline after stopping.
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
        await working?.value
    }

    /// Transcribes what is left once the recorder has closed the files, which by then have moved to
    /// `mic` and `remote` in the library. nil when a piece still fails or no word was heard.
    public func finish(mic: URL, remote: URL) async -> Transcription? {
        let started = ContinuousClock.now
        await prepareForMove()
        self.mic = mic
        self.remote = remote
        guard await isConfigurationCurrent() else {
            try? FileManager.default.removeItem(at: scratch)
            return nil
        }
        // A temporary network failure leaves `cut` at the last fully successful pair of tracks.
        // Retry that piece rather than sending the whole meeting again.
        failed = false
        defer { try? FileManager.default.removeItem(at: scratch) }
        await run { await self.transcribePieces(final: true) }
        guard await isConfigurationCurrent() else { return nil }
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
        await task.value
    }

    private func transcribePieces(final: Bool) async {
        while !failed, final || !isFinishing {
            guard await isConfigurationCurrent() else { failed = true; return }
            do {
                let available = min(try WAVFormat.frameCount(mic), try WAVFormat.frameCount(remote))
                let rate = try WAVFormat.read(mic, frames: 0..<1).sampleRate
                let piece = max(1, Int(pieceSeconds * Double(rate)))
                let search = min(piece, Int(Self.searchSeconds * Double(rate)))
                var end = available
                if !final || available - cut > piece {
                    guard available - cut >= piece else { return }
                    // End the piece where both tracks are quietest, so no word is cut in half.
                    let from = cut + piece - search
                    let tail = (try WAVFormat.read(mic, frames: from..<cut + piece), try WAVFormat.read(remote, frames: from..<cut + piece))
                    end = from + QuietCut.index(mic: tail.0.samples, remote: tail.1.samples, window: rate * 3 / 10)
                    // Keep profile frames on one global timeline. Otherwise each piece's
                    // partial 50 ms tail adds another frame and accumulated echo stats drift.
                    let grid = max(1, Int(EchoCanceller.profileFrame * Double(rate)))
                    end = max((cut / grid + 1) * grid, ((end + grid / 2) / grid) * grid)
                    guard end <= available else { return }
                }
                guard end > cut else { return }
                let range = cut..<end
                let started = ContinuousClock.now
                async let mine = transcribe(.me, mic, range, rate, echoOf: remote)
                async let theirs = transcribe(.remote, remote, range, rate)
                let (a, b) = try await (mine, theirs)
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
                if !final, await isConfigurationCurrent(), !isFinishing, let transcript = currentTranscription,
                   let manifest = try? RecordingManifest.read(from: mic.deletingLastPathComponent()) {
                    await processing?.checkpoint(transcript, manifest: manifest)
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
