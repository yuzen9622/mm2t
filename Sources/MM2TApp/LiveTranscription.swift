import Foundation
import MM2TLocal
import MM2TCore
import MM2TProviders
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

    private let hostedMeeting: String?
    private var mic: URL
    private var remote: URL
    private let chain: TranscriptionChain
    private let hints: [String]
    private let pieceSeconds: TimeInterval
    private let scratch: URL
    private let keepsPlayback: Bool
    private var playbackWriter: WAVWriter?
    private var playbackFailed = false
    private let now: @Sendable () -> Date
    public let processing: LiveRecordingProcessor?
    private let configurationIsCurrent: @MainActor @Sendable () -> Bool
    private var invalidated = false

    private var cut = 0
    private var words: [Track: [TimedWord]] = [.me: [], .remote: []]
    private var sources: [Track: TranscriptionSource] = [:]
    private var echo: EchoProfile?
    private var aec: AEC3?
    // STT can fail after AEC3 processed the pair. Retry the PCM, not the adaptive filter.
    private struct PreparedPiece {
        let range: Range<Int>
        let mic: EchoCanceller.Result
        let remote: [Int16]
        let rawMicIsSilent: Bool
    }
    private var prepared: PreparedPiece?
    private var failed = false
    private var consecutiveFailures = 0
    private var retryAfter: Date?
    private var isFinishing = false
    private var working: Task<Void, Never>?

    /// `mic` and `remote` are the files the recorder is writing. `scratch` holds each piece while it uploads.
    public init(mic: URL, remote: URL, chain: TranscriptionChain, hints: [String], scratch: URL,
                hostedMeeting: String? = nil, pieceSeconds: TimeInterval = LiveTranscriber.pieceSeconds, now: @escaping @Sendable () -> Date = Date.init,
                processing: LiveRecordingProcessor? = nil, keepsPlayback: Bool = false,
                configurationIsCurrent: @escaping @MainActor @Sendable () -> Bool = { true }) {
        self.hostedMeeting = hostedMeeting
        self.mic = mic
        self.remote = remote
        self.chain = chain
        self.hints = hints
        self.scratch = scratch
        self.pieceSeconds = hostedMeeting == nil ? pieceSeconds : Double(HostedTranscription.recordingPieceSeconds)
        self.now = now
        self.processing = processing
        self.keepsPlayback = keepsPlayback
        self.configurationIsCurrent = configurationIsCurrent
    }

    /// Seconds of the recording transcribed so far.
    public private(set) var transcribedSeconds: TimeInterval = 0

    /// Transcribes every whole piece the recording has grown past. Call it now and then while recording;
    /// a call made while an earlier one is still working waits for it rather than starting a second.
    var pollingInterval: Duration { chain.routes.first?.source == .local ? .milliseconds(200) : .seconds(2) }

    public func advance() async {
        guard await isConfigurationCurrent(), !isFinishing else { return }
        if let working { await working.value; return }
        if let retryAfter, now() < retryAfter { return }
        failed = false
        let task = Task { await self.transcribePieces(final: false) }
        working = task
        await task.value
        working = nil
    }

    /// Cancel the live request without making durable storage wait for its provider.
    public func prepareForMove() async {
        isFinishing = true
        working?.cancel()
        await processing?.stopCheckpoints()
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
        defer {
            try? playbackWriter?.close()
            playbackWriter = nil
            try? FileManager.default.removeItem(at: scratch)
        }
        guard !Task.isCancelled else { await processing?.discard(); return nil }
        self.mic = mic
        self.remote = remote
        guard await isConfigurationCurrent() else {
            return nil
        }
        // A temporary network failure leaves `cut` at the last fully successful pair of tracks.
        // Retry that piece rather than sending the whole meeting again.
        failed = false
        await transcribePieces(final: true)
        if let hostedMeeting, let hosted = chain.routes.first?.provider as? HostedTranscription {
            await hosted.releaseRecording(hostedMeeting)
        }
        guard !Task.isCancelled, await isConfigurationCurrent() else { await processing?.discard(); return nil }
        await processing?.finish()
        guard await isConfigurationCurrent() else { return nil }
        // Nothing heard at all is more likely this class judging quiet speech silent than a meeting
        // without a word, so that case is left to the whole-file transcription too.
        guard !failed, let transcript = currentTranscription,
              !(transcript.me.words.isEmpty && transcript.remote.words.isEmpty) else {
            Self.logger.notice("event=live_finish result=whole_file_fallback elapsed_seconds=\(Self.seconds(since: started), privacy: .public) completed_audio_seconds=\(self.transcribedSeconds, privacy: .public)")
            return nil
        }
        if !playbackFailed, let writer = playbackWriter {
            if (try? writer.close()) != nil {
                PlaybackMic.keep(writer.url, beside: mic)
            }
            playbackWriter = nil
        }
        Self.logger.info("event=live_finish result=reused elapsed_seconds=\(Self.seconds(since: started), privacy: .public) completed_audio_seconds=\(self.transcribedSeconds, privacy: .public)")
        if let hostedMeeting { await chain.finishSession(meeting: hostedMeeting) }
        return transcript
    }

    func discard() async {
        await prepareForMove()
        await working?.value
        await processing?.discard()
        if let hostedMeeting { await chain.finishSession(meeting: hostedMeeting) }
        try? playbackWriter?.close()
        try? FileManager.default.removeItem(at: scratch)
    }

    public func isConfigurationCurrent() async -> Bool {
        let current = await configurationIsCurrent()
        if !invalidated, current { return true }
        if !invalidated, let hostedMeeting { await chain.finishSession(meeting: hostedMeeting) }
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
        // Checkpoints use the same gate on the available prefix, without deleting buffered words.
        // A later piece can extend a run; only finish decides from the complete recording.
        let micWords = words[.me]!
        let keptMicWords = echo?.droppingEcho(from: micWords) ?? micWords
        return Transcription(
            me: TrackTranscript(source: sources[.me] ?? fallback, content: .unlabeled(keptMicWords)),
            remote: TrackTranscript(source: sources[.remote] ?? fallback, content: .unlabeled(words[.remote]!)))
    }

    private func transcribePieces(final: Bool) async {
        while !Task.isCancelled, !failed, final || !isFinishing {
            guard await isConfigurationCurrent() else { failed = true; return }
            guard final || !isFinishing else { return }
            do {
                let micFrames = try WAVFormat.frameCount(mic), remoteFrames = try WAVFormat.frameCount(remote)
                // Preserve remote-only speech after the mic ends via the whole-file path.
                if final && remoteFrames > micFrames { failed = true; return }
                let available = final ? micFrames : min(micFrames, remoteFrames)
                let rate = try WAVFormat.read(mic, frames: 0..<1).sampleRate
                guard rate == (try WAVFormat.read(remote, frames: 0..<1)).sampleRate else { failed = true; return }
                let remaining = Double(available - cut) / Double(rate)
                let mlx = chain.routes.first?.provider is BreezeMLX
                let seconds = mlx ? 30 : chain.routes.first?.source == .local
                    ? Self.breezeWindow(remaining: remaining, finishing: final) : pieceSeconds
                let piece = max(1, Int(seconds * Double(rate)))
                let search = min(piece / 2, Int(Self.searchSeconds * Double(rate)))
                var end = available
                if let prepared {
                    guard prepared.range.lowerBound == cut, prepared.range.upperBound <= available else {
                        failed = true
                        return
                    }
                    end = prepared.range.upperBound
                } else if !final || available - cut > piece {
                    guard available - cut >= piece else { return }
                    // End the piece where both tracks are quietest, so no word is cut in half.
                    if mlx || hostedMeeting != nil {
                        end = cut + piece
                    } else {
                        let from = cut + piece - search
                        let tail = try WAVFormat.read(mic, frames: from..<cut + piece).samples
                        let render = try Self.render(remote, range: from..<cut + piece, available: remoteFrames)
                        end = from + QuietCut.index(mic: tail, remote: render, window: rate * 3 / 10)
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
                let pieceAudio = try preparePiece(range, rate: rate, remoteFrames: remoteFrames)
                let hasTail = final && end < available && available - end <= piece
                if hasTail, let hostedMeeting, let hosted = chain.routes.first?.provider as? HostedTranscription,
                   await hosted.canParallelizeTail(of: hostedMeeting, through: Double(available) / Double(rate)) {
                    guard await isConfigurationCurrent(), !Task.isCancelled else { failed = true; return }
                    async let first = transcribePair(range, rate: rate, piece: pieceAudio)
                    let tail = try readPiece(end..<available, rate: rate, remoteFrames: remoteFrames)
                    async let last = transcribePair(tail.range, rate: rate, piece: tail)
                    await appendForSeparation(pieceAudio, rate: rate)
                    await appendForSeparation(tail, rate: rate)
                    await processing?.finish()
                    let results = try await (first, last)
                    guard await isConfigurationCurrent(), !Task.isCancelled else { failed = true; return }
                    commit(pieceAudio, result: results.0, rate: rate)
                    commit(tail, result: results.1, rate: rate)
                    return
                }
                let finishingAudio = final && end == available
                async let recognition = transcribePair(range, rate: rate, piece: pieceAudio)
                if finishingAudio {
                    await appendForSeparation(pieceAudio, rate: rate)
                    await processing?.finish()
                }
                let result = try await recognition
                guard await isConfigurationCurrent() else { failed = true; return }
                guard !Task.isCancelled else { return }
                if !finishingAudio {
                    // A stop may cancel this loop and move the source WAVs during the append.
                    await Task { await appendForSeparation(pieceAudio, rate: rate) }.value
                }
                commit(pieceAudio, result: result, rate: rate)
                consecutiveFailures = 0
                retryAfter = nil
                Self.logger.info("event=live_piece elapsed_seconds=\(Self.seconds(since: started), privacy: .public) audio_seconds=\(Double(range.count) / Double(rate), privacy: .public)")
                if let processing, !final, await isConfigurationCurrent(), !isFinishing, let transcript = currentTranscription,
                   let manifest = try? RecordingManifest.read(from: mic.deletingLastPathComponent()) {
                    await processing.checkpoint(transcript, manifest: manifest)
                }
                if final, end == available { return }
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
                consecutiveFailures += 1
                let delay = min(120.0, 30.0 * pow(2, Double(min(consecutiveFailures - 1, 2))))
                retryAfter = now().addingTimeInterval(delay)
                Self.logger.notice("event=live_piece_failed retry_after_seconds=\(delay, privacy: .public) completed_audio_seconds=\(self.transcribedSeconds, privacy: .public)")
            }
        }
    }

    private func appendForSeparation(_ piece: PreparedPiece, rate: Int) async {
        await processing?.append(cleaned: piece.mic, remote: piece.remote, rate: rate, range: piece.range)
    }

    private func commit(_ piece: PreparedPiece, result: (Piece, Piece), rate: Int) {
        for (track, heard) in [(Track.me, result.0), (.remote, result.1)] {
            words[track]! += heard.words
            if let source = heard.source { sources[track] = source }
        }
        if let profile = result.0.echo {
            let base = echo ?? EchoProfile(frameDuration: profile.frameDuration, before: [], after: [])
            echo = base.appending(profile, at: Double(piece.range.lowerBound) / Double(rate))
        }
        appendPlayback(piece.mic.samples, rate: rate)
        cut = piece.range.upperBound
        prepared = nil
        transcribedSeconds = Double(cut) / Double(rate)
    }

    private func appendPlayback(_ samples: [Int16], rate: Int) {
        guard keepsPlayback, !playbackFailed else { return }
        do {
            if playbackWriter == nil {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                playbackWriter = try WAVWriter(url: scratch.appending(path: "playback-mic.wav"), sampleRate: rate)
            }
            playbackWriter?.appendPCM(samples)
            try playbackWriter?.flush()
        } catch {
            playbackFailed = true
            Self.logger.notice("event=live_playback_mic_write_failed")
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    private typealias Piece = (words: [TimedWord], source: TranscriptionSource?, echo: EchoProfile?)

    private static func render(_ url: URL, range: Range<Int>, available: Int) throws -> [Int16] {
        guard range.lowerBound < available else { return [] }
        return try WAVFormat.read(url, frames: range.lowerBound..<min(range.upperBound, available)).samples
    }

    private func transcribePair(_ range: Range<Int>, rate: Int, piece: PreparedPiece) async throws -> (Piece, Piece) {
        let cleaned = piece.mic, theirs = piece.remote
        let profile = cleaned.echo
        guard rate == 16_000, chain.routes.count == 1, chain.routes[0].source == .local,
              let breeze = chain.routes[0].provider as? any TrackTranscriber else {
            async let micWords = piece.rawMicIsSilent
                ? ([], nil, profile) : transcribe(.me, samples: cleaned.samples, range, rate, echo: profile)
            async let remoteWords = QuietCut.isSilent(theirs)
                ? ([], nil, nil) : transcribe(.remote, samples: theirs, range, rate)
            return try await (micWords, remoteWords)
        }
        let channels = [cleaned.samples, theirs]
        let active = channels.indices.filter { !QuietCut.isSilent(channels[$0]) }
        let pcm = active.map { channels[$0].map { Float($0) / 32768 } }
        let results = try await breeze.transcribeTracks(pcm, hints: hints)
        var pieces: [Piece] = [([], nil, profile), ([], nil, nil)]
        let offset = Double(range.lowerBound) / Double(rate)
        for (channel, words) in zip(active, results) {
            pieces[channel].words = words.map {
                TimedWord(text: $0.text, range: TimeRange(start: $0.range.start + offset, end: $0.range.end + offset))
            }
            pieces[channel].source = .local
        }
        return (pieces[0], pieces[1])
    }

    private func preparePiece(_ range: Range<Int>, rate: Int, remoteFrames: Int) throws -> PreparedPiece {
        if let prepared { return prepared }
        let piece = try readPiece(range, rate: rate, remoteFrames: remoteFrames)
        prepared = piece
        return piece
    }

    private func readPiece(_ range: Range<Int>, rate: Int, remoteFrames: Int) throws -> PreparedPiece {
        let mine = try WAVFormat.read(mic, frames: range).samples
        let theirs = try Self.render(remote, range: range, available: remoteFrames)
        if rate == AEC3.sampleRate, aec == nil { aec = AEC3() }
        let cleaned = aec?.clean(mic: mine, remote: theirs)
            ?? EchoCanceller.clean(mic: mine, remote: theirs, sampleRate: rate)
            ?? EchoCanceller.Result(samples: mine, echo: EchoCanceller.unchangedProfile(mic: mine, sampleRate: rate))
        return PreparedPiece(range: range, mic: cleaned, remote: theirs, rawMicIsSilent: QuietCut.isSilent(mine))
    }

    private nonisolated func transcribe(_ track: Track, samples: [Int16], _ range: Range<Int>, _ rate: Int,
                                        echo: EchoProfile? = nil) async throws -> Piece {
        let audio = WAVAudio(sampleRate: rate, samples: samples)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let file = scratch.appending(path: "\(track.rawValue)-\(range.lowerBound).wav")
        try WAVFormat.write(audio, to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let context = hostedMeeting.map { TranscriptionContext(meeting: $0, track: track, recordingOffset: range.lowerBound / rate) }
        let transcript = try await TranscriptionContext.$current.withValue(context) {
            try await chain.transcribe(audio: file, hints: hints, labelSpeakers: false)
        }
        let offset = Double(range.lowerBound) / Double(rate)
        let words = transcript.words.map {
            TimedWord(text: $0.text, range: TimeRange(start: $0.range.start + offset, end: $0.range.end + offset))
        }
        Self.logger.info("event=live_track track=\(track.rawValue, privacy: .public) source=\(transcript.source.rawValue, privacy: .public) start_seconds=\(offset, privacy: .public) audio_seconds=\(Double(range.count) / Double(rate), privacy: .public) words=\(words.count, privacy: .public)")
        return (words, transcript.source, echo)
    }
}
