import Foundation
import MM2TCore
import MM2TSystem
import OSLog

public struct LiveProcessingProgress: Sendable {
    public let transcribedSeconds: TimeInterval
    public let diarizedSeconds: TimeInterval
    public let checkpointSeconds: TimeInterval
    public let checkpointBusy: Bool
    public let recordingProcessingEnabled: Bool
    /// Closed audio examined by the successful checkpoint, including confirmed silence.
    /// `checkpointSeconds` separately reports the last utterance actually sent to the LLM.
    public let checkpointAudioSeconds: TimeInterval

    public init(transcribedSeconds: TimeInterval, diarizedSeconds: TimeInterval, checkpointSeconds: TimeInterval,
                checkpointBusy: Bool, recordingProcessingEnabled: Bool, checkpointAudioSeconds: TimeInterval = 0) {
        self.transcribedSeconds = transcribedSeconds
        self.diarizedSeconds = diarizedSeconds
        self.checkpointSeconds = checkpointSeconds
        self.checkpointBusy = checkpointBusy
        self.recordingProcessingEnabled = recordingProcessingEnabled
        self.checkpointAudioSeconds = checkpointAudioSeconds
    }
}

/// One recording owns its model state, audio span cache and speculative LLM requests.
/// Failed speculation cannot mark a meeting complete: the ordinary pipeline remains the fallback.
public actor LiveRecordingProcessor {
    private static let logger = Logger(subsystem: "dev.mm2t.app", category: "Processing")
    public let pipeline: MeetingProcessingPipeline
    private let session: any StreamingDiarizationSession
    private let scratch: URL
    private let configurationIsCurrent: @MainActor @Sendable () -> Bool
    private var writers: [Track: WAVWriter] = [:]
    private var frames = 0
    private var echo: EchoProfile?
    private var failed = false
    private var isFinishing = false
    private var checkpointsStopped = false
    private var finalSnapshot: StreamingDiarizationSnapshot?
    private var checkpointTask: Task<Void, Never>?
    private struct CheckpointRequest: Sendable {
        let transcription: Transcription
        let manifest: RecordingManifest
        let seconds: TimeInterval
    }
    private var checkpointInProgress = false
    private var pendingCheckpoint: CheckpointRequest?
    private var lastSuccessfulInputSeconds: TimeInterval = 0
    private var checkpointSeconds: TimeInterval = 0
    private var checkpointAudioSeconds: TimeInterval = 0
    private var diarizedSeconds: TimeInterval = 0

    public init(pipeline: MeetingProcessingPipeline, session: any StreamingDiarizationSession, scratch: URL,
                configurationIsCurrent: @escaping @MainActor @Sendable () -> Bool = { true }) {
        self.pipeline = pipeline
        self.session = session
        self.scratch = scratch
        self.configurationIsCurrent = configurationIsCurrent
    }

    /// Called exactly once for each successful, contiguous speech-recognition piece. Echo removal
    /// uses the same piece boundaries as STT, so embeddings and words hear the same mic signal.
    public func append(mic: URL, remote: URL, range: Range<Int>) async {
        guard !failed, !isFinishing else { return }
        do {
            guard range.lowerBound == frames else { throw LiveProcessingError.noncontiguousAudio }
            let mine = try WAVFormat.read(mic, frames: range)
            let theirs = try WAVFormat.read(remote, frames: range)
            guard mine.sampleRate == 16_000, theirs.sampleRate == 16_000,
                  mine.samples.count == range.count, theirs.samples.count == range.count
            else { throw LiveProcessingError.unsupportedAudio }
            let cleaned = EchoCanceller.clean(mic: mine.samples, remote: theirs.samples, sampleRate: mine.sampleRate)
            let profile = cleaned?.echo ?? EchoCanceller.unchangedProfile(mic: mine.samples, sampleRate: mine.sampleRate)
            let base = echo ?? EchoProfile(frameDuration: profile.frameDuration, before: [], after: [])
            echo = base.appending(profile, at: Double(frames) / 16_000)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            for (track, pcm) in [(Track.me, cleaned?.samples ?? mine.samples), (.remote, theirs.samples)] {
                let writer: WAVWriter
                if let existing = writers[track] { writer = existing }
                else {
                    writer = try WAVWriter(url: audioURL(track), sampleRate: 16_000)
                    writers[track] = writer
                }
                let samples = pcm.map { Float($0) / Float(Int16.max) }
                samples.withUnsafeBufferPointer { writer.append($0) }
                try writer.flush()
                try await session.append(samples: samples, track: track)
            }
            frames = range.upperBound
            let processed = await session.processedSeconds()
            if let mic = processed[.me], let remote = processed[.remote] {
                diarizedSeconds = max(diarizedSeconds, min(mic, remote))
            }
        } catch {
            failed = true
            Self.logger.notice("event=recording_preparation_failed phase=audio")
        }
    }

    public func checkpoint(_ transcription: Transcription, manifest: RecordingManifest) async {
        let seconds = Double(frames) / 16_000
        guard !failed, !isFinishing, !checkpointsStopped, seconds - lastSuccessfulInputSeconds >= 30 else { return }
        // A slow LLM must not lose the newest prefix when recording pauses or no further
        // piece arrives. Retain one latest request, rather than a queue of obsolete drafts.
        pendingCheckpoint = CheckpointRequest(transcription: transcription, manifest: manifest, seconds: seconds)
        guard !checkpointInProgress else { return }
        checkpointInProgress = true
        await startNextCheckpoint()
    }

    private func startNextCheckpoint() async {
        guard !failed, !isFinishing, !checkpointsStopped, let request = pendingCheckpoint else {
            pendingCheckpoint = nil
            checkpointInProgress = false
            return
        }
        pendingCheckpoint = nil
        guard request.seconds - lastSuccessfulInputSeconds >= 30 else {
            checkpointInProgress = false
            return
        }
        do {
            let snapshot = try await session.snapshot(tracks: audioURLs, final: false)
            guard await canCheckpoint() else { checkpointInProgress = false; return }
            let processed = min(snapshot.processedSeconds[.me] ?? 0, snapshot.processedSeconds[.remote] ?? 0)
            diarizedSeconds = max(diarizedSeconds, processed)
            // Appends may arrive during snapshot creation; the request contains words only
            // through its captured input watermark, even if model state is further ahead.
            let covered = min(processed, request.seconds)
            guard covered > 0 else { await startNextCheckpoint(); return }
            // Avoid lending the LLM words whose speaker frames have not arrived yet.
            let prefix = Transcription(me: request.transcription.me.before(covered), remote: request.transcription.remote.before(covered))
            let manifest = request.manifest
            let metadata = MeetingMetadata(title: manifest.title, startedAt: manifest.startedAt,
                                           duration: covered, platform: manifest.platform,
                                           timeZoneIdentifier: manifest.timeZoneIdentifier ?? TimeZone.current.identifier)
            let draft = await pipeline.recordingDraft(transcription: prefix, diarizations: snapshot.diarizations,
                echo: echo, metadata: metadata, highlights: manifest.highlights.map(Highlight.init(time:)))
            guard await canCheckpoint() else { checkpointInProgress = false; return }
            let preparedThrough = draft.utterances.map(\.range.end).max() ?? 0
            let pipeline = self.pipeline
            checkpointTask = Task {
                guard await self.canCheckpoint() else {
                    self.checkpointTask = nil
                    self.checkpointInProgress = false
                    return
                }
                let succeeded: Bool
                if draft.utterances.isEmpty { succeeded = true }
                else { succeeded = await pipeline.precomputeRecording(draft) }
                await self.completedCheckpoint(preparedThrough, audioSeconds: draft.metadata.duration,
                                               inputSeconds: request.seconds, succeeded: succeeded)
            }
        } catch {
            // The next checkpoint retries; finalization can still use the streaming model state.
            Self.logger.notice("event=recording_preparation_failed phase=checkpoint")
            await startNextCheckpoint()
        }
    }

    private func completedCheckpoint(_ seconds: TimeInterval, audioSeconds: TimeInterval,
                                     inputSeconds: TimeInterval, succeeded: Bool) async {
        if succeeded, !failed {
            checkpointSeconds = seconds
            checkpointAudioSeconds = audioSeconds
            lastSuccessfulInputSeconds = inputSeconds
        }
        checkpointTask = nil
        Self.logger.info("event=recording_checkpoint audio_seconds=\(seconds, privacy: .public) succeeded=\(succeeded, privacy: .public)")
        await startNextCheckpoint()
    }

    public func finish() async {
        guard !isFinishing else { return }
        isFinishing = true
        pendingCheckpoint = nil
        defer { closeAudio() }
        guard !failed else { return }
        do {
            finalSnapshot = try await session.snapshot(tracks: audioURLs, final: true)
            diarizedSeconds = min(finalSnapshot?.processedSeconds[.me] ?? 0, finalSnapshot?.processedSeconds[.remote] ?? 0)
        } catch {
            failed = true
            Self.logger.notice("event=recording_preparation_failed phase=finish")
        }
    }

    /// Stop starting speculative work as soon as recording stops. The active LLM request can
    /// still warm the cache, and append remains available for the final transcription pieces.
    public func stopCheckpoints() {
        checkpointsStopped = true
        pendingCheckpoint = nil
    }

    private func canCheckpoint() async -> Bool {
        guard !isFinishing, !checkpointsStopped else { return false }
        let current = await configurationIsCurrent()
        guard current, !failed else { discard(); return false }
        return !isFinishing && !checkpointsStopped
    }

    public func discard() {
        failed = true
        isFinishing = true
        pendingCheckpoint = nil
        checkpointTask?.cancel()
        checkpointTask = nil
        closeAudio()
    }

    private func closeAudio() {
        for writer in writers.values { try? writer.close() }
        writers = [:]
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Returns false when the ordinary full-audio separation must run instead.
    public func attach(_ transcription: Transcription, to id: MeetingID) async throws -> Bool {
        guard !failed, let finalSnapshot else { return false }
        try await pipeline.attachRecording(transcription, diarizations: finalSnapshot.diarizations, echo: echo, to: id)
        return true
    }

    public func progress(transcribedSeconds: TimeInterval) -> LiveProcessingProgress {
        LiveProcessingProgress(transcribedSeconds: transcribedSeconds, diarizedSeconds: diarizedSeconds,
            checkpointSeconds: checkpointSeconds, checkpointBusy: checkpointInProgress,
            recordingProcessingEnabled: !failed, checkpointAudioSeconds: checkpointAudioSeconds)
    }

    private var audioURLs: [Track: URL] { [.me: audioURL(.me), .remote: audioURL(.remote)] }
    private func audioURL(_ track: Track) -> URL { scratch.appending(path: "\(track.rawValue).wav") }
    private enum LiveProcessingError: Error { case noncontiguousAudio, unsupportedAudio }
}

private extension TrackTranscript {
    func before(_ time: TimeInterval) -> TrackTranscript {
        // Live STT is unlabeled; the final pipeline retains the complete, untrimmed transcript.
        TrackTranscript(source: source, content: .unlabeled(words.filter { $0.range.end <= time }))
    }
}
