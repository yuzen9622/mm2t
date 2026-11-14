import AppKit
import MM2TApp
import MM2TCore
import MM2TDiarization
import MM2TProviders
import MM2TSystem

/// Debug-only replay through CaptureController, with content-free measurements.
@MainActor
enum DebugBenchmark {
    #if DEBUG
    private static let env = ProcessInfo.processInfo.environment
    private static let replay = BenchmarkRecorder()
    private static var mode: String { env["MM2T_BENCH_MODE"] ?? (env["MM2T_BENCH_MEETING"] == nil ? "timed" : "batch") }
    static var isRequested: Bool { env["MM2T_BENCH_OUT"] != nil }
    static var recorderOverride: (any Recorder)? { isRequested && ["timed", "accelerated"].contains(mode) ? replay : nil }
    static var permissionsOverride: (any PermissionsProviding)? { recorderOverride == nil ? nil : BenchmarkPermissions() }
    #else
    static var isRequested: Bool { false }
    static var recorderOverride: (any Recorder)? { nil }
    static var permissionsOverride: (any PermissionsProviding)? { nil }
    #endif

    static func run(app: AppController) {
        #if DEBUG
        Task {
            var report: [String: Any] = ["schema_version": 4, "mode": mode, "acceptance_eligible": false,
                                       "quality_review_required": true]
            let sampled = BenchmarkProgress()
            var recordingStarted: ContinuousClock.Instant?
            defer { write(report); NSApp.terminate(nil) }
            do {
                try requireIsolatedRoot(app.paths.root)
                guard ["timed", "accelerated", "batch", "llm"].contains(mode) else { throw BenchmarkFailure.invalidMode }
                report["setup_issue_count"] = app.setup.issues.count
                if mode != "llm", !app.setup.issues.isEmpty { throw BenchmarkFailure.needsSetup }
                report["stt_order"] = app.settings.settings.transcriptionOrder.map(\.rawValue)
                report["diarization_order"] = app.settings.settings.diarizationOrder.map(\.rawValue)
                report["llm_location"] = app.settings.settings.llmLocation.rawValue
                report["cloud_llm"] = app.settings.settings.cloudLLM.rawValue
                report["llm_model"] = app.settings.settings.cloudLLM == .gemini
                    ? GeminiLLM.defaultModel : app.settings.settings.openAIModel
                report["logical_processors"] = ProcessInfo.processInfo.activeProcessorCount
                if mode == "llm" {
                    try await runLLMDiagnostic(app, report: &report)
                    return
                }
                if mode == "batch" {
                    let meeting = try await batchMeeting(app)
                    let started = ContinuousClock.now
                    await app.queue.run(.process, on: meeting.id)
                    report["queue_seconds"] = seconds(since: started)
                    let done = try await app.library.meeting(meeting.id)
                    report.merge(validation(done, job: app.queue.jobs[done.id])) { _, new in new }
                    return
                }
                guard try await app.library.list().isEmpty else { throw BenchmarkFailure.libraryNotEmpty }
                await app.capture.startNow(title: "Benchmark")
                guard let session = await replay.session else { throw BenchmarkFailure.recordingNotStarted }
                let started = ContinuousClock.now
                recordingStarted = started
                sampled.phase = "recording"
                let source = session.source
                report["input_duration_seconds"] = source.duration
                report["metadata_duration_seconds"] = source.metadata.duration
                report["input_frames"] = source.frames
                report["sample_rate"] = source.rate
                report["metadata_preserved"] = source.hasOriginalMetadata
                var releaseAhead = 0.0
                var releasedFrames = 0
                let progressReport = report
                let sampler = Task {
                    var nextReport = 0.0
                    while !Task.isCancelled {
                        let latest = await app.capture.liveProgress()
                        let fields = progressFields(latest)
                        guard !Task.isCancelled else { return }
                        sampled.latest = latest
                        sampled.fields = fields
                        sampled.recordingSeconds = seconds(since: started)
                        if sampled.recordingSeconds >= nextReport {
                            var progress = progressReport
                            progress["phase"] = sampled.phase
                            progress["recording_wall_seconds"] = sampled.recordingSeconds
                            progress["released_audio_seconds"] = sampled.releasedAudioSeconds
                            progress["live"] = fields
                            progress["prefix_wait"] = sampled.waitFields
                            write(progress, progress: true)
                            nextReport = sampled.recordingSeconds + 30
                        }
                        try? await Task.sleep(for: mode == "timed" ? .seconds(30) : .milliseconds(250))
                    }
                }
                defer { sampler.cancel() }
                if mode == "timed" {
                    // Only the recorder sees the source. Processing reads the growing WAVs,
                    // whose physically available samples never run ahead of the monotonic clock.
                    let deadline = started.advanced(by: .seconds(source.duration))
                    while true {
                        let elapsed = seconds(since: started)
                        if elapsed >= source.duration { break }
                        let frames = min(source.frames, Int(elapsed * Double(source.rate)))
                        try await session.release(through: frames)
                        releasedFrames = frames
                        sampled.releasedAudioSeconds = Double(frames) / Double(source.rate)
                        releaseAhead = max(releaseAhead, Double(frames) / Double(source.rate) - seconds(since: started))
                        let nextRelease = min(deadline, ContinuousClock.now.advanced(by: .milliseconds(250)))
                        try await ContinuousClock().sleep(until: nextRelease, tolerance: .zero)
                    }
                } else {
                    // Diagnostic only: a deliberate head start, with optional fresh audio
                    // withheld until stop(). It can never establish the real-time target.
                    let tailSeconds: Double
                    if let raw = env["MM2T_BENCH_DIAGNOSTIC_TAIL_SECONDS"] {
                        guard let value = Double(raw), value.isFinite, value >= 0, value <= source.duration
                        else { throw BenchmarkFailure.invalidDiagnosticTail }
                        tailSeconds = value
                    } else { tailSeconds = min(20, source.duration) }
                    report["diagnostic_requested_tail_seconds"] = tailSeconds
                    let prefixFrames = source.frames - Int((tailSeconds * Double(source.rate)).rounded())
                    var released = 0
                    while released < prefixFrames {
                        released = min(prefixFrames, released + source.rate * 60)
                        try await session.release(through: released)
                        releasedFrames = released
                        sampled.releasedAudioSeconds = Double(released) / Double(source.rate)
                        try await waitForPrefix(seconds: Double(released) / Double(source.rate), sampled: sampled)
                    }
                    report["diagnostic_headstart"] = true
                }
                // Use the latest nonblocking sample. Awaiting model actors for a fresh
                // measurement here could unintentionally let them drain before the timer.
                report["before_stop"] = sampled.fields
                report["before_stop_sample_age_seconds"] = seconds(since: started) - sampled.recordingSeconds
                let releasedSeconds = Double(releasedFrames) / Double(source.rate)
                report["released_before_stop_seconds"] = releasedSeconds
                report["stop_tail_audio_seconds"] = source.duration - releasedSeconds
                report["prefix_wait_total_seconds"] = sampled.prefixWaitSeconds
                report["prefix_wait_count"] = sampled.prefixWaitCount
                if mode == "timed" { report["max_release_ahead_seconds"] = releaseAhead }
                // No draining is allowed here. session.stop() writes the withheld tail
                // inside CaptureController.stop(), so its upload and processing are timed.
                sampled.phase = "stopping"
                let stop = ContinuousClock.now
                await app.capture.stop()
                let completed = ContinuousClock.now
                let stopSeconds = seconds(since: stop, until: completed)
                let stopDispatchedAfter = seconds(since: started, until: stop)
                let totalSeconds = seconds(since: started, until: completed)
                report["stop_to_completed_seconds"] = stopSeconds
                report["recording_wall_seconds"] = stopDispatchedAfter
                report["total_wall_seconds"] = totalSeconds
                if mode == "timed" {
                    report["stop_dispatch_delay_seconds"] = max(0, stopDispatchedAfter - source.duration)
                    report["audio_deadline_to_completed_seconds"] = max(0, totalSeconds - source.duration)
                }
                let meetings = try await app.library.list()
                guard meetings.count == 1, let done = meetings.first else { throw BenchmarkFailure.missingResult }
                let result = validation(done, job: app.queue.jobs[done.id])
                report.merge(result) { _, new in new }
                let eligible = mode == "timed" && source.hasOriginalMetadata && releaseAhead <= 1 / Double(source.rate)
                report["acceptance_eligible"] = eligible
                let allOutputs = result["all_outputs_complete"] as? Bool == true
                report["capture_stop_timing_passed"] = eligible && allOutputs && stopSeconds <= 10
                // A delayed main actor must not grant extra preparation time before a
                // short stop call and make the timed replay appear to meet the target.
                report["target_timing_passed"] = eligible && allOutputs && totalSeconds - source.duration <= 10
                report["diagnostic_stop_under_ten_seconds"] = mode == "accelerated" && stopSeconds <= 10
            } catch {
                // Do not await the processing actors again after a timeout: the stalled
                // actor being diagnosed must not prevent the failure report from being saved.
                report["last_progress"] = sampled.fields
                report["phase"] = sampled.phase
                report["released_audio_seconds"] = sampled.releasedAudioSeconds
                report["prefix_wait"] = sampled.waitFields
                report["prefix_wait_total_seconds"] = sampled.prefixWaitSeconds
                report["prefix_wait_count"] = sampled.prefixWaitCount
                if let recordingStarted {
                    report["recording_wall_seconds"] = seconds(since: recordingStarted)
                    report["last_progress_sample_age_seconds"] = seconds(since: recordingStarted) - sampled.recordingSeconds
                }
                // Descriptions can contain provider response bodies, paths or credentials.
                report["failure"] = (error as? BenchmarkFailure)?.rawValue ?? "executionFailed"
                report["error_type"] = String(reflecting: type(of: error))
            }
        }
        #endif
    }

    #if DEBUG
    private static func requireIsolatedRoot(_ root: URL) throws {
        let actual = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "mm2t")
        guard root.resolvingSymlinksInPath().standardizedFileURL != actual.resolvingSymlinksInPath().standardizedFileURL,
              root.path.hasPrefix("/Volumes/KINGSTON/"), env["MM2T_DEFAULTS_SUITE"]?.isEmpty == false else {
            throw BenchmarkFailure.isolationRequired
        }
    }

    private static func batchMeeting(_ app: AppController) async throws -> Meeting {
        if let raw = env["MM2T_BENCH_MEETING"], let id = UUID(uuidString: raw) {
            return try await app.library.meeting(MeetingID(id))
        }
        let source = try BenchmarkSource.load()
        let staging = app.paths.root.appending(path: "benchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let mic = staging.appending(path: "mic.wav"), remote = staging.appending(path: "remote.wav")
        try FileManager.default.copyItem(at: source.mic, to: mic)
        try FileManager.default.copyItem(at: source.remote, to: remote)
        return try await app.library.create(Recording(micTrack: mic, remoteTrack: remote, highlights: source.highlights, metadata: source.metadata))
    }

    /// Reuses saved audio-derived data to exercise a recording provider's checkpoint and
    /// final update. This intentionally measures neither capture nor transcription latency.
    private static func runLLMDiagnostic(_ app: AppController, report: inout [String: Any]) async throws {
        report["acceptance_eligible"] = false
        report["target_timing_passed"] = false
        report["semantic_diagnostic_only"] = true
        report["capture_executed"] = false
        report["queue_executed"] = false
        report["stt_executed"] = false
        report["diarization_executed"] = false
        report["saved_transcription_reused"] = true
        report["saved_speaker_attribution_reused"] = true
        report["saved_llm_outputs_reused"] = false
        report["audio_files_copied"] = false
        let settings = app.settings.settings
        guard settings.llmLocation == .cloud, settings.cloudLLM == .gemini else {
            throw BenchmarkFailure.unsupportedLLMDiagnosticProvider
        }
        guard try await app.library.list().isEmpty else { throw BenchmarkFailure.libraryNotEmpty }
        guard let path = env["MM2T_BENCH_SOURCE"],
              let cutoff = Double(env["MM2T_BENCH_LLM_PREFIX_SECONDS"] ?? "2853.2"),
              cutoff.isFinite, cutoff > 0 else { throw BenchmarkFailure.invalidSource }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: URL(filePath: path))
        let source = try decoder.decode(Meeting.self, from: data)
        guard source.transcription != nil, source.attribution?.source != nil,
              !source.utterances.isEmpty, cutoff < source.metadata.duration,
              var document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let utterances = document["utterances"] as? [[String: Any]] else {
            throw BenchmarkFailure.invalidSource
        }
        // Keep an exact prefix, including stable IDs and overlapping-turn ordering. Filtering
        // individual ranges could create holes that invalidate the incremental provider cache.
        let prefixCount = source.utterances.prefix { $0.range.end <= cutoff + 0.000001 }.count
        guard prefixCount > 0, prefixCount < source.utterances.count,
              utterances.count == source.utterances.count else { throw BenchmarkFailure.invalidDiagnosticPrefix }
        document["id"] = UUID().uuidString
        document["outputs"] = ["isStale": true]
        let encoder = JSONEncoder()
        document["status"] = try JSONSerialization.jsonObject(with: encoder.encode(ProcessingStatus.pending(next: .inferNames)))
        let full = try decoder.decode(Meeting.self, from: JSONSerialization.data(withJSONObject: document))
        document["utterances"] = Array(utterances.prefix(prefixCount))
        var metadata = document["metadata"] as? [String: Any] ?? [:]
        metadata["duration"] = cutoff
        document["metadata"] = metadata
        let prefix = try decoder.decode(Meeting.self, from: JSONSerialization.data(withJSONObject: document))
        report["input_duration_seconds"] = source.metadata.duration
        report["metadata_preserved"] = full.metadata == source.metadata && full.highlights == source.highlights
        report["raw_inputs_preserved"] = full.transcription == source.transcription && full.utterances == source.utterances
        report["speaker_inputs_preserved"] = full.speakers == source.speakers
            && full.mergedSpeakers == source.mergedSpeakers && full.attribution == source.attribution
            && full.micSegments == source.micSegments && full.remoteSegments == source.remoteSegments
        report["warm_prefix_requested_seconds"] = cutoff
        report["warm_prefix_utterances"] = prefixCount
        report["warm_prefix_last_utterance_end_seconds"] = prefix.utterances.map(\.range.end).max() ?? 0
        report["final_added_utterances"] = full.utterances.count - prefixCount
        let service = env["MM2T_KEYCHAIN_SERVICE"] ?? KeychainCredentialStore.defaultService + ".debug"
        let credentials = KeychainCredentialStore(service: service)
        guard let key = try credentials.read(.geminiAPIKey), !key.isEmpty else { throw BenchmarkFailure.needsSetup }
        let llm = GeminiLLM(apiKey: key).forRecording()
        let pipeline = MeetingProcessingPipeline(
            library: app.library, voiceprints: app.voiceprints, diarizer: nil, embedder: nil,
            diarizationOrder: [], transcription: TranscriptionChain([]), llm: llm,
            thresholds: .weSpeaker, vocabulary: settings.vocabulary, runsConcurrently: true)
        report["phase"] = "warming_llm_prefix"
        write(report, progress: true)
        let warmStarted = ContinuousClock.now
        let warmed = await pipeline.precomputeRecording(prefix)
        report["warm_checkpoint_seconds"] = seconds(since: warmStarted)
        report["warm_checkpoint_succeeded"] = warmed
        guard warmed else { throw BenchmarkFailure.llmWarmupFailed }
        // The same provider instance retains normalization and summary/digest checkpoints.
        // Existing generated outputs never enter its caches; cleanup is generated afresh.
        try await app.library.save(full)
        report["phase"] = "final_llm_update"
        write(report, progress: true)
        let finalStarted = ContinuousClock.now
        report["queue_executed"] = true
        await app.queue.run(.regenerate, on: full.id, using: pipeline)
        report["final_llm_seconds"] = seconds(since: finalStarted)
        let done = try await app.library.meeting(full.id)
        report.merge(validation(done, job: app.queue.jobs[full.id])) { _, new in new }
        report["phase"] = "finished"
    }

    private static func waitForPrefix(seconds released: Double, sampled: BenchmarkProgress) async throws {
        let started = ContinuousClock.now
        let timeout = max(1, Double(env["MM2T_BENCH_PREFIX_TIMEOUT_SECONDS"] ?? "180") ?? 180)
        sampled.phase = "waiting_for_prefix"
        sampled.prefixWaitCount += 1
        sampled.waitFields = ["released_audio_seconds": released, "timeout_seconds": timeout,
                              "required_transcribed_seconds": max(0, released - 30),
                              "required_diarized_seconds": max(0, released - 65),
                              "required_checkpoint_audio_seconds": max(0, released - 130),
                              "checkpoint_required": released >= 150, "completed": false]
        defer {
            let elapsed = seconds(since: started)
            sampled.prefixWaitSeconds += elapsed
            sampled.waitFields["elapsed_seconds"] = elapsed
        }
        while seconds(since: started) < timeout {
            // The independent sampler may itself wait on a busy actor. Inspecting its
            // cache keeps this deadline bounded even if that actor stops responding.
            if let p = sampled.latest {
                guard p.recordingProcessingEnabled else { throw BenchmarkFailure.liveProcessingUnavailable }
                let transcriptionReady = p.transcribedSeconds >= max(0, released - 30)
                let diarizationReady = p.diarizedSeconds >= max(0, released - 65)
                let checkpointReady = released < 150 || (p.checkpointAudioSeconds >= released - 130 && !p.checkpointBusy)
                sampled.waitFields["transcription_ready"] = transcriptionReady
                sampled.waitFields["diarization_ready"] = diarizationReady
                sampled.waitFields["checkpoint_ready"] = checkpointReady
                sampled.waitFields["elapsed_seconds"] = seconds(since: started)
                if transcriptionReady, diarizationReady, checkpointReady {
                    sampled.waitFields["completed"] = true
                    sampled.phase = "recording"
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw BenchmarkFailure.prefixTimeout
    }

    private static func progressFields(_ p: LiveProcessingProgress?) -> [String: Any] {
        guard let p else { return ["available": false] }
        return ["available": true, "transcribed_seconds": p.transcribedSeconds, "diarized_seconds": p.diarizedSeconds,
                "checkpoint_seconds": p.checkpointSeconds, "checkpoint_audio_seconds": p.checkpointAudioSeconds,
                "checkpoint_busy": p.checkpointBusy,
                "recording_processing_enabled": p.recordingProcessingEnabled]
    }

    private static func validation(_ meeting: Meeting, job: JobState?) -> [String: Any] {
        let complete: Bool
        if case .completed = meeting.status { complete = true } else { complete = false }
        let jobComplete = job == .completed
        let outputs = meeting.outputs
        let sourceIDs = Set(meeting.utterances.map(\.id))
        let duplicateUtteranceIDs = meeting.utterances.count - sourceIDs.count
        let paragraphs = outputs.cleaned?.paragraphs ?? []
        let cleanedIDs = Set(paragraphs.flatMap(\.sources))
        let summary = outputs.summary
        let digests = outputs.digests ?? []
        let digestPoints = digests.flatMap(\.points)
        let decisions = summary?.decisions ?? []
        let discussionPoints = summary?.discussionPoints ?? []
        let actions = summary?.actionItems ?? []
        var references: [UtteranceID] = paragraphs.flatMap(\.sources)
        for point in digestPoints { references.append(contentsOf: point.sources) }
        for item in decisions { references.append(contentsOf: item.sources) }
        for item in discussionPoints { references.append(contentsOf: item.sources) }
        for item in actions { references.append(contentsOf: item.sources) }
        let invalidSourceReferences = references.filter { !sourceIDs.contains($0) }.count
        let emptySources: [String: Int] = [
            "cleaned_paragraphs": paragraphs.filter { $0.sources.isEmpty }.count,
            "digest_points": digestPoints.filter { $0.sources.isEmpty }.count,
            "decisions": decisions.filter { $0.sources.isEmpty }.count,
            "discussion_points": discussionPoints.filter { $0.sources.isEmpty }.count,
            "action_items": actions.filter { $0.sources.isEmpty }.count,
        ]
        let emptySourceItems = emptySources.values.reduce(0, +)
        let knownSpeakers = Set(meeting.speakers.map(\.id)).union([SpeakerID.me])
        func knownSpeaker(_ speaker: SpeakerID) -> Bool {
            knownSpeakers.contains(meeting.resolve(speaker))
        }
        let invalidSpeakers: [String: Int] = [
            "utterances": meeting.utterances.filter { !knownSpeaker($0.speaker) }.count,
            "cleaned_paragraphs": paragraphs.filter { !knownSpeaker($0.speaker) }.count,
            "digests": digests.filter { !knownSpeaker($0.speaker) }.count,
            "remote_segments": meeting.remoteSegments.filter { !knownSpeaker($0.speaker) }.count,
            "mic_segments": (meeting.micSegments ?? []).filter { !knownSpeaker($0.speaker) }.count,
        ]
        let invalidSpeakerReferences = invalidSpeakers.values.reduce(0, +)
        let invalidActionOwners = actions.filter { action in
            action.owner.map { !knownSpeaker($0) } ?? false
        }.count
        let validReferences = invalidSourceReferences == 0
        let validStructure = validReferences && emptySourceItems == 0 && duplicateUtteranceIDs == 0
            && invalidSpeakerReferences == 0 && invalidActionOwners == 0
        let transcriptionPresent = meeting.transcription != nil
        let attributionPresent = meeting.attribution?.source != nil
        let llmPresent = !paragraphs.isEmpty && outputs.digests != nil && summary != nil
        let allOutputs = complete && jobComplete && transcriptionPresent && attributionPresent
            && !meeting.utterances.isEmpty && llmPresent && !outputs.isStale && validStructure
        var result: [String: Any] = [:]
        result["completed"] = complete
        result["job_completed"] = jobComplete
        result["transcription_present"] = transcriptionPresent
        result["speaker_attribution_present"] = attributionPresent
        result["attribution_source"] = meeting.attribution?.source?.rawValue ?? "none"
        result["speakers"] = meeting.speakers.count
        result["utterances"] = meeting.utterances.count
        result["duplicate_utterance_ids"] = duplicateUtteranceIDs
        result["utterance_end_seconds"] = meeting.utterances.map { $0.range.end }.max() ?? 0
        result["cleaned_present"] = outputs.cleaned != nil
        result["paragraphs"] = paragraphs.count
        result["cleaned_utterances_covered"] = cleanedIDs.count
        result["cleaned_utterances_omitted"] = sourceIDs.subtracting(cleanedIDs).count
        result["valid_source_references"] = validReferences
        result["invalid_source_references"] = invalidSourceReferences
        result["empty_source_items"] = emptySourceItems
        result["empty_source_items_by_output"] = emptySources
        result["invalid_speaker_references"] = invalidSpeakerReferences
        result["invalid_speaker_references_by_output"] = invalidSpeakers
        result["invalid_action_owners"] = invalidActionOwners
        result["output_structure_valid"] = validStructure
        result["digests_present"] = outputs.digests != nil
        result["digests"] = outputs.digests?.count ?? 0
        result["summary_present"] = summary != nil
        result["action_items"] = actions.count
        result["action_items_with_due"] = actions.filter { $0.due != nil }.count
        result["action_items_with_due_time"] = actions.filter { $0.due?.hasTime == true }.count
        result["outputs_stale"] = outputs.isStale
        result["all_outputs_complete"] = allOutputs
        return result
    }

    private static func seconds(since start: ContinuousClock.Instant, until end: ContinuousClock.Instant = .now) -> Double {
        let c = start.duration(to: end).components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    private static func write(_ report: [String: Any], progress: Bool = false) {
        guard let path = env["MM2T_BENCH_OUT"], let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(filePath: path + (progress ? ".progress.json" : "")), options: .atomic)
    }
    #endif
}

#if DEBUG
@MainActor
private final class BenchmarkProgress {
    var latest: LiveProcessingProgress?
    var fields: [String: Any] = ["available": false]
    var waitFields: [String: Any] = [:]
    var recordingSeconds = 0.0
    var releasedAudioSeconds = 0.0
    var prefixWaitSeconds = 0.0
    var prefixWaitCount = 0
    var phase = "preparing"
}

private enum BenchmarkFailure: String, Error {
    case invalidMode, invalidSource, isolationRequired, libraryNotEmpty, recordingNotStarted
    case liveProcessingUnavailable, prefixTimeout, missingResult, alreadyStopped, needsSetup, invalidDiagnosticTail
    case unsupportedLLMDiagnosticProvider, invalidDiagnosticPrefix, llmWarmupFailed
}

private struct BenchmarkSource: Sendable {
    let mic: URL
    let remote: URL
    let metadata: MeetingMetadata
    let highlights: [Highlight]
    let rate: Int
    let frames: Int
    let hasOriginalMetadata: Bool
    var duration: Double { Double(frames) / Double(rate) }

    static func load() throws -> Self {
        let env = ProcessInfo.processInfo.environment
        let mic: URL, remote: URL, metadata: MeetingMetadata?, highlights: [Highlight]
        if let path = env["MM2T_BENCH_SOURCE"] {
            struct Document: Decodable {
                let metadata: MeetingMetadata
                let audio: RecordingAudio
                let highlights: [Highlight]
            }
            let url = URL(filePath: path)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(Document.self, from: Data(contentsOf: url))
            mic = url.deletingLastPathComponent().appending(path: document.audio.micFile)
            remote = url.deletingLastPathComponent().appending(path: document.audio.remoteFile)
            metadata = document.metadata
            highlights = document.highlights
        } else if let a = env["MM2T_BENCH_MIC"], let b = env["MM2T_BENCH_REMOTE"] {
            mic = URL(filePath: a)
            remote = URL(filePath: b)
            metadata = nil
            highlights = []
        } else { throw BenchmarkFailure.invalidSource }
        let a = try WAVFormat.read(mic, frames: 0..<1), b = try WAVFormat.read(remote, frames: 0..<1)
        guard a.sampleRate > 0, a.sampleRate == b.sampleRate else { throw BenchmarkFailure.invalidSource }
        let frames = max(try WAVFormat.frameCount(mic), try WAVFormat.frameCount(remote))
        guard frames > 0 else { throw BenchmarkFailure.invalidSource }
        return Self(mic: mic, remote: remote,
                    metadata: metadata ?? MeetingMetadata(title: "Benchmark", startedAt: Date(), duration: Double(frames) / Double(a.sampleRate)),
                    highlights: highlights, rate: a.sampleRate, frames: frames, hasOriginalMetadata: metadata != nil)
    }
}

private actor BenchmarkRecorder: Recorder {
    private(set) var session: BenchmarkSession?
    func start(_ configuration: RecorderConfiguration) async throws -> any RecordingSession {
        let session = try BenchmarkSession(source: BenchmarkSource.load(), directory: configuration.directory)
        self.session = session
        return session
    }
}

private actor BenchmarkSession: RecordingSession {
    nonisolated let events: AsyncStream<RecorderEvent>
    let source: BenchmarkSource
    private let continuation: AsyncStream<RecorderEvent>.Continuation
    private let mic: URL, remote: URL
    private let micWriter: FileHandle, remoteWriter: FileHandle
    private var manifest: RecordingManifest
    private var released = 0
    private var stopped = false
    var elapsed: TimeInterval { Double(released) / Double(source.rate) }

    init(source: BenchmarkSource, directory: URL) throws {
        self.source = source
        var manifest = RecordingManifest(title: source.metadata.title, startedAt: source.metadata.startedAt,
                                         platform: source.metadata.platform, targetBundleID: nil,
                                         timeZoneIdentifier: source.metadata.timeZoneIdentifier ?? TimeZone.current.identifier)
        manifest.highlights = source.highlights.map(\.time)
        self.manifest = manifest
        (events, continuation) = AsyncStream.makeStream()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        mic = directory.appending(path: "mic.wav")
        remote = directory.appending(path: "remote.wav")
        try WAVFormat.write(WAVAudio(sampleRate: source.rate, samples: []), to: mic)
        try WAVFormat.write(WAVAudio(sampleRate: source.rate, samples: []), to: remote)
        micWriter = try FileHandle(forWritingTo: mic)
        remoteWriter = try FileHandle(forWritingTo: remote)
        try micWriter.seekToEnd()
        try remoteWriter.seekToEnd()
        try manifest.write(to: directory)
    }

    func release(through frame: Int) throws {
        guard !stopped else { throw BenchmarkFailure.alreadyStopped }
        let end = min(source.frames, max(released, frame))
        guard end > released else { return }
        for (input, writer) in [(source.mic, micWriter), (source.remote, remoteWriter)] {
            let available = try WAVFormat.frameCount(input)
            var samples = released < available ? try WAVFormat.read(input, frames: released..<min(end, available)).samples : []
            samples += repeatElement(Int16(0), count: end - released - samples.count)
            let bytes = samples.map(\.littleEndian).withUnsafeBufferPointer { Data(buffer: $0) }
            try writer.write(contentsOf: bytes)
        }
        released = end
    }

    func pause() async {}
    func resume() async {}
    func markHighlight() async throws -> Highlight { Highlight(time: elapsed) }
    func stop() async throws -> Recording {
        try release(through: source.frames)
        stopped = true
        for writer in [micWriter, remoteWriter] {
            try writer.seek(toOffset: 4)
            var riffSize = UInt32(36 + released * 2).littleEndian
            try withUnsafeBytes(of: &riffSize) { try writer.write(contentsOf: Data($0)) }
            try writer.seek(toOffset: 40)
            var dataSize = UInt32(released * 2).littleEndian
            try withUnsafeBytes(of: &dataSize) { try writer.write(contentsOf: Data($0)) }
            try writer.synchronize()
            try writer.close()
        }
        manifest.duration = source.metadata.duration
        try manifest.write(to: mic.deletingLastPathComponent())
        continuation.finish()
        return Recording(micTrack: mic, remoteTrack: remote, highlights: source.highlights, metadata: source.metadata)
    }
}

private struct BenchmarkPermissions: PermissionsProviding {
    var microphone: PermissionState { .granted }
    var systemAudio: PermissionState { .granted }
    var accessibility: PermissionState { .granted }
    func requestMicrophone() async -> Bool { true }
    func requestAccessibility() {}
    func automation(of bundleID: String) -> PermissionState { .granted }
    func requestAutomation(of bundleID: String) async -> PermissionState { .granted }
}
#endif
