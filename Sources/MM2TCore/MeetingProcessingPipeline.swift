import Foundation
import OSLog

public enum SpeakerSeparationError: Error, Equatable {
    /// Re-running separation needs a finished meeting; a failed one resumes with `process` instead.
    case meetingNotCompleted(ProcessingStatus)
}

/// Turns a recorded meeting into a transcript with speakers and LLM outputs.
/// Every step persists its result before the next starts, so a retry resumes at the failed step.
public struct MeetingProcessingPipeline: Sendable {
    private static let logger = Logger(subsystem: "dev.mm2t.app", category: "Processing")
    public let library: MeetingLibrary
    public let voiceprints: VoiceprintStore
    public let diarizer: (any Diarizer)?
    public let embedder: (any SpeakerEmbedder)?
    /// Sources tried in order for the remote track's speaker turns.
    public let diarizationOrder: [DiarizationSource]
    public let transcription: TranscriptionChain
    public let llm: (any LLMProvider)?
    public let thresholds: MatchThresholds
    public let vocabulary: [String]
    /// Whether name inference and the three generated views run at once. Hosted LLMs can do so
    /// even when speech recognition has a local fallback; an on-device LLM stays serial.
    public let runsConcurrently: Bool
    /// Independent of LLM execution: a speech chain that may reach a local model stays serial.
    public let transcribesConcurrently: Bool
    /// Removes the speakers' echo of the remote track from the mic track before it is transcribed
    /// and separated. nil leaves the mic as recorded.
    public let micCleaner: (any MicCleaner)?
    var outputLanguage: @Sendable () -> MeetingOutputLanguage = { .current }
    private let isSilentTrack: @Sendable (URL) -> Bool

    public init(
        library: MeetingLibrary,
        voiceprints: VoiceprintStore,
        diarizer: (any Diarizer)?,
        embedder: (any SpeakerEmbedder)?,
        diarizationOrder: [DiarizationSource] = [.local, .transcription],
        transcription: TranscriptionChain,
        llm: (any LLMProvider)?,
        thresholds: MatchThresholds,
        vocabulary: [String],
        runsConcurrently: Bool = false,
        transcribesConcurrently: Bool? = nil,
        micCleaner: (any MicCleaner)? = nil,
        isSilentTrack: @escaping @Sendable (URL) -> Bool = { _ in false }
    ) {
        self.runsConcurrently = runsConcurrently
        self.transcribesConcurrently = transcribesConcurrently ?? runsConcurrently
        self.micCleaner = micCleaner
        self.isSilentTrack = isSilentTrack
        self.library = library
        self.voiceprints = voiceprints
        self.diarizer = diarizer
        self.embedder = embedder
        self.diarizationOrder = diarizationOrder
        self.transcription = transcription
        self.llm = llm
        self.thresholds = thresholds
        self.vocabulary = vocabulary
    }

    /// Recording snapshots are private drafts. They warm the same provider instance that will
    /// finish this meeting, but never persist an incomplete meeting or overwrite a user's edits.
    public func recordingDraft(transcription: Transcription, diarizations: [Track: Diarization],
                               echo: EchoProfile?, metadata: MeetingMetadata, highlights: [Highlight],
                               audioURLs: [Track: URL] = [:], micEnergy: SpeechEnergy? = nil) async -> Meeting {
        var meeting = Meeting(id: MeetingID(), metadata: metadata,
                              audio: RecordingAudio(micFile: "mic.wav", remoteFile: "remote.wav"), highlights: highlights)
        meeting.transcription = Transcription(me: transcription.me.inTraditionalChinese, remote: transcription.remote.inTraditionalChinese)
        await diarize(&meeting, recorded: diarizations, echo: echo, audioURLs: audioURLs, micEnergy: micEnergy)
        await matchVoiceprints(&meeting)
        align(&meeting)
        // A continuing speaker may extend the last utterance. Only a closed prefix is offered
        // to rolling summaries, so the next snapshot can refer to exactly the same source IDs.
        var closedThrough = max(0, metadata.duration - Alignment.maxPause)
        if let open = meeting.utterances.firstIndex(where: { $0.range.end > closedThrough }) {
            closedThrough = min(closedThrough, meeting.utterances[open].range.start)
            meeting.utterances = Array(meeting.utterances.prefix(open))
        }
        // This private draft covers confirmed silence too; last spoken word time alone cannot
        // express how far background work has caught up during a quiet part of the meeting.
        meeting.metadata.duration = closedThrough
        meeting.status = .pending(next: .inferNames)
        return meeting
    }

    /// Speculative generation only warms successful, exact-input responses. A final changed
    /// transcript, speaker assignment, highlight or date necessarily requests a fresh result.
    public func precomputeRecording(_ draft: Meeting) async -> Bool {
        guard runsConcurrently, let llm else { return false }
        guard !draft.utterances.isEmpty else { return true }
        let generation = withLLM(await llm.forGeneration())
        let language = outputLanguage()
        return await withTaskGroup(of: Bool.self) { group in
            for step in ProcessingStep.allCases where step >= .inferNames {
                group.addTask {
                    var copy = draft
                    do { try await generation.run(step, on: &copy, language: language); return true }
                    catch { return false }
                }
            }
            var succeeded = true
            for await result in group { succeeded = succeeded && result }
            return succeeded
        }
    }

    /// Installs only finalized audio-derived results; generated outputs still run through the
    /// normal completion/error path with the actual saved recording's metadata and highlights.
    public func attachRecording(_ transcription: Transcription, diarizations: [Track: Diarization],
                                echo: EchoProfile?, to id: MeetingID, micEnergy: SpeechEnergy? = nil) async throws {
        var meeting = try await library.meeting(id)
        guard meeting.status == .pending(next: .transcribe) else { return }
        meeting.transcription = Transcription(me: transcription.me.inTraditionalChinese, remote: transcription.remote.inTraditionalChinese)
        await diarize(&meeting, recorded: diarizations, echo: echo, micEnergy: micEnergy)
        await matchVoiceprints(&meeting)
        Self.logger.info("event=live_speakers_matched")
        align(&meeting)
        meeting.status = .pending(next: .inferNames)
        try await library.save(meeting)
    }

    public func withLLM(_ provider: any LLMProvider) -> MeetingProcessingPipeline {
        MeetingProcessingPipeline(library: library, voiceprints: voiceprints, diarizer: diarizer, embedder: embedder,
            diarizationOrder: diarizationOrder, transcription: transcription, llm: provider, thresholds: thresholds,
            vocabulary: vocabulary, runsConcurrently: runsConcurrently, transcribesConcurrently: transcribesConcurrently,
            micCleaner: micCleaner, isSilentTrack: isSilentTrack)
    }

    /// Runs from the meeting's resume step to the end. A step failure is recorded in
    /// `meeting.status` and returned, not thrown; only persistence errors throw.
    @discardableResult
    public func process(
        _ id: MeetingID,
        resumeDeferredAI: Bool = false,
        progress: @Sendable (ProcessingStep) -> Void = { _ in }
    ) async throws -> Meeting {
        var meeting = try await library.meeting(id)
        if resumeDeferredAI {
            guard llm != nil, let deferred = meeting.deferredAIStep else { return meeting }
            meeting.status = .pending(next: max(deferred, meeting.status.resumeStep ?? deferred))
            try await library.save(meeting)
        } else if case .failed(let step, _) = meeting.status {
            meeting.status = .pending(next: step)
            try await library.save(meeting)
        }
        var generationLanguage: MeetingOutputLanguage?
        while let step = meeting.status.resumeStep {
            if step >= .inferNames {
                // A meeting can contain only background voices. Do not generate content from an empty transcript.
                if meeting.utterances.isEmpty {
                    try Task.checkCancellation()
                    meeting.outputs = LLMOutputs()
                    meeting.suggestions = NameSuggestions()
                    meeting.summaryMarkdown = nil
                    meeting.perPersonMarkdown = nil
                    meeting.translation = nil
                    meeting.deferredAIStep = nil
                    meeting.status = .completed
                    try await library.save(meeting)
                    return meeting
                }
                guard let llm else {
                    try Task.checkCancellation()
                    meeting.deferredAIStep = step
                    meeting.status = .completed
                    try await library.save(meeting)
                    return meeting
                }
                let language = generationLanguage ?? outputLanguage()
                generationLanguage = language
                if runsConcurrently {
                    // One label for the group: the summary is the part the user is waiting for.
                    progress(.summarize)
                    try await generate(from: step, using: llm, on: &meeting, language: language)
                    return meeting
                }
            }
            progress(step)
            do {
                try await run(step, on: &meeting, language: generationLanguage ?? outputLanguage())
                // Some steps fall back instead of throwing; a cancelled one must not count as done.
                try Task.checkCancellation()
                meeting.status = step.next.map { .pending(next: $0) } ?? .completed
                if meeting.status == .completed { meeting.deferredAIStep = nil }
            } catch {
                // A stop the user asked for leaves the meeting waiting at this step, ready to resume.
                if Task.isCancelled { throw CancellationError() }
                meeting.status = .failed(step: step, reason: String(describing: error))
                try await library.save(meeting)
                return meeting
            }
            try await library.save(meeting)
        }
        return meeting
    }

    /// Runs `first` and every step after it at once. None of them reads another's result, so the
    /// wait is the slowest one rather than their sum. Each result is saved as it arrives; a failure
    /// leaves the meeting failed at the earliest step that failed, and a retry runs from there.
    private func generate(from first: ProcessingStep, using llm: any LLMProvider, on meeting: inout Meeting, language: MeetingOutputLanguage) async throws {
        let steps = ProcessingStep.allCases.filter { $0 >= first }
        let start = meeting
        let generation = withLLM(await llm.forGeneration())
        var failures: [ProcessingStep: String] = [:]
        await withTaskGroup(of: (ProcessingStep, Result<Meeting, any Error>).self) { group in
            for step in steps {
                group.addTask {
                    var copy = start
                    do {
                        try await generation.run(step, on: &copy, language: language)
                        return (step, .success(copy))
                    } catch {
                        return (step, .failure(error))
                    }
                }
            }
            for await (step, result) in group {
                switch result {
                case .success(let done): merge(step, from: done, into: &meeting)
                case .failure(let error): failures[step] = String(describing: error)
                }
                try? await library.save(meeting)
            }
        }
        if Task.isCancelled {
            // What finished is kept; the rest runs again from `first` when the user resumes.
            meeting.status = .pending(next: first)
            try await library.save(meeting)
            throw CancellationError()
        } else if let failed = steps.first(where: { failures[$0] != nil }) {
            meeting.status = .failed(step: failed, reason: failures[failed]!)
        } else {
            meeting.status = .completed
            meeting.deferredAIStep = nil
        }
        try await library.save(meeting)
    }

    /// Copies what `step` wrote, leaving what the other concurrent steps wrote in place.
    private func merge(_ step: ProcessingStep, from done: Meeting, into meeting: inout Meeting) {
        switch step {
        case .inferNames: meeting.suggestions = done.suggestions
        case .cleanTranscript: meeting.outputs.cleaned = done.outputs.cleaned
        case .digestPerPerson:
            meeting.outputs.digests = done.outputs.digests
            meeting.perPersonMarkdown = nil
        case .summarize:
            meeting.outputs.summary = done.outputs.summary
            meeting.summaryMarkdown = nil
            meeting.outputs.isStale = done.outputs.isStale
            meeting.metadata.title = done.metadata.title
        case .transcribe, .diarize, .matchVoiceprints, .align:
            preconditionFailure("\(step) feeds later steps and cannot run alongside them")
        }
    }

    /// Re-runs name inference and the three generated views, e.g. after a merge made them stale.
    @discardableResult
    public func regenerateLLMOutputs(
        _ id: MeetingID,
        progress: @Sendable (ProcessingStep) -> Void = { _ in }
    ) async throws -> Meeting {
        var meeting = try await library.meeting(id)
        if meeting.status.resumeStep.map({ $0 > .inferNames }) ?? true {
            meeting.status = .pending(next: .inferNames)
            try await library.save(meeting)
        }
        return try await process(id, progress: progress)
    }

    private func run(_ step: ProcessingStep, on meeting: inout Meeting, language: MeetingOutputLanguage) async throws {
        let started = ContinuousClock.now
        var succeeded = false
        defer {
            let elapsed = started.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            Self.logger.info("event=processing_step step=\(step.rawValue, privacy: .public) elapsed_seconds=\(seconds, privacy: .public) succeeded=\(succeeded, privacy: .public)")
        }
        try await perform(step, on: &meeting, language: language)
        succeeded = true
    }

    private func perform(_ step: ProcessingStep, on meeting: inout Meeting, language: MeetingOutputLanguage) async throws {
        switch step {
        case .transcribe:
            let names = await voiceprints.spokenNames()
            let hints = names + vocabulary.filter { !names.contains($0) }
            let micURL = await library.audioURL(meeting, track: .me), remoteURL = await library.audioURL(meeting, track: .remote)
            let remoteIsSilent = isSilentTrack(remoteURL)
            let cleaned = remoteIsSilent ? nil : try? micCleaner?.clean(mic: micURL, remote: remoteURL)
            // Playback wants the same track, and cleaning it again there is slow for a long meeting.
            defer { if let cleaned { PlaybackMic.keep(cleaned.audio, beside: micURL) } }
            let heardURL = cleaned?.audio ?? micURL
            let remote: TrackTranscript
            var me: TrackTranscript
            // Speaker labels serve only the separation that falls back on them.
            let labels = diarizationOrder.contains(.transcription)
            let id = meeting.id.description, transcription = transcription
            @Sendable func transcribe(_ track: Track, _ audio: URL, labelSpeakers: Bool) async throws -> TrackTranscript {
                try await TranscriptionContext.$current.withValue(TranscriptionContext(meeting: id, track: track)) {
                    try await transcription.transcribe(audio: audio, hints: hints, labelSpeakers: labelSpeakers)
                }
            }
            if remoteIsSilent {
                me = try await transcribe(.me, heardURL, labelSpeakers: labels)
                remote = TrackTranscript(source: me.source, content: .unlabeled([]))
            } else if transcribesConcurrently {
                // Both at once, so the mic is labeled before anyone knows whether it needs to be.
                async let remoteTask = transcribe(.remote, remoteURL, labelSpeakers: labels)
                async let meTask = transcribe(.me, heardURL, labelSpeakers: labels)
                (remote, me) = try await (remoteTask, meTask)
            } else {
                remote = try await transcribe(.remote, remoteURL, labelSpeakers: labels)
                // A silent remote track means the meeting happened in the room, so the mic holds every
                // voice and is the track whose speakers need telling apart.
                me = try await transcribe(.me, heardURL, labelSpeakers: labels && remote.words.isEmpty)
            }
            // Only after both tracks: a failed stage keeps the plan's session, so a retry reuses its pieces.
            await transcription.finishSession(meeting: id)
            if let echo = cleaned?.echo { me = me.dropping(echo) }
            meeting.transcription = Transcription(me: me.inTraditionalChinese, remote: remote.inTraditionalChinese)

        case .diarize:
            await diarize(&meeting)

        case .matchVoiceprints:
            await matchVoiceprints(&meeting)

        case .align:
            align(&meeting)

        case .inferNames:
            guard let llm else { return }
            let speaking = Set(meeting.utterances.map(\.speaker))
            let unnamed = meeting.speakers.filter { $0.person == nil && speaking.contains($0.id) }.map(\.id)
            let voiceprintSuggestions = meeting.suggestions.items.filter {
                if case .voiceprint = $0.source { return unnamed.contains($0.speaker) }
                return false
            }
            var inferred: [NameSuggestion] = []
            if !unnamed.isEmpty {
                let names = await voiceprints.names()
                let known = meeting.speakers.reduce(into: [SpeakerID: String]()) { result, speaker in
                    if let name = speaker.person.flatMap({ names[$0] }) { result[speaker.id] = name }
                }
                let transcript = llmTranscript(meeting, language: language)
                let guesses = try await llm.inferNames(NameInferenceRequest(
                    transcript: transcript, unnamedSpeakers: unnamed, knownNames: known))
                inferred = guesses
                    .map { NameGuess(speaker: $0.speaker, name: TraditionalChinese.convert($0.name), reason: $0.reason) }
                    .filter { unnamed.contains($0.speaker) && Self.isSpoken($0.name, in: transcript) }
                    .map { NameSuggestion(speaker: $0.speaker, source: .inferred(
                        name: $0.name, reason: TraditionalChinese.convert($0.reason))) }
            }
            meeting.suggestions = NameSuggestions(items: voiceprintSuggestions + inferred)

        case .cleanTranscript:
            guard let llm else { return }
            var transcript = llmTranscript(meeting, language: language)
            let names = await voiceprints.spokenNames()
            transcript.glossary = names + vocabulary.filter { !names.contains($0) }
            meeting.outputs.cleaned = try await llm.cleanTranscript(transcript)
            meeting.joinCleanedFragments()

        case .digestPerPerson:
            guard let llm else { return }
            var transcript = llmTranscript(meeting, language: language)
            let names = await voiceprints.spokenNames()
            transcript.glossary = names + vocabulary.filter { !names.contains($0) }
            let digests = try await llm.digestPerPerson(transcript)
            meeting.outputs.digests = language == .traditionalChinese ? digests.map(\.inTraditionalChinese) : digests

        case .summarize:
            guard let llm else { return }
            var transcript = llmTranscript(meeting, language: language)
            let names = await voiceprints.spokenNames()
            transcript.glossary = names + vocabulary.filter { !names.contains($0) }
            let summary = try await llm.summarize(SummaryRequest(
                transcript: transcript,
                prioritized: transcript.utterances.filter(\.isHighlighted),
                meetingStartedAt: meeting.metadata.startedAt,
                timeZoneIdentifier: meeting.metadata.timeZoneIdentifier ?? TimeZone.current.identifier))
            let localizedSummary = language == .traditionalChinese ? summary.inTraditionalChinese : summary
            meeting.outputs.summary = localizedSummary
            meeting.outputs.isStale = false
            // The recorder can only name a meeting after its app ("Google Meet") or "Recording".
            if let title = localizedSummary.title, !meeting.metadata.isTitleEdited { meeting.metadata.title = title }
        }
    }

    /// Re-runs speaker separation, voiceprint matching and alignment on the stored transcription,
    /// e.g. after the local model is fixed. STT is not called again. Speakers are rebuilt, which
    /// discards persons the user assigned and merges; LLM outputs and name suggestions were written
    /// for the old speakers, so they become stale as after a merge. A run that still cannot separate
    /// keeps the current speakers and outputs, and only refreshes an unseparated meeting's failure reason.
    @discardableResult
    public func reseparateSpeakers(_ id: MeetingID) async throws -> Meeting {
        var meeting = try await library.meeting(id)
        guard meeting.status == .completed else { throw SpeakerSeparationError.meetingNotCompleted(meeting.status) }
        meeting.status = .pending(next: .diarize)
        try await library.save(meeting)

        var separated = meeting
        await diarize(&separated)
        if Task.isCancelled {
            // Separation falls back when stopped, so its result is not kept.
            meeting.status = .completed
            try await library.save(meeting)
            throw CancellationError()
        }
        if case .unseparated = separated.attribution {
            if case .unseparated = meeting.attribution { meeting.attribution = separated.attribution }
        } else {
            await matchVoiceprints(&separated)
            align(&separated)
            separated.suggestions.isStale = true
            let outputs = separated.outputs
            if outputs.cleaned != nil || outputs.digests != nil || outputs.summary != nil {
                separated.outputs.isStale = true
            }
            meeting = separated
        }
        meeting.status = .completed
        try await library.save(meeting)
        return meeting
    }

    /// Never fails: when every source is unavailable or throws, the meeting keeps its transcript
    /// under one unnamed speaker and records why, so the user can re-run separation later.
    private func diarize(_ meeting: inout Meeting, recorded: [Track: Diarization]? = nil, echo: EchoProfile? = nil,
                         audioURLs: [Track: URL] = [:], micEnergy: SpeechEnergy? = nil) async {
        guard let transcription = meeting.transcription else { preconditionFailure("diarize before transcribe") }
        let track: Track = transcription.remote.words.isEmpty && !transcription.me.words.isEmpty ? .me : .remote
        let transcript = track == .me ? transcription.me : transcription.remote
        let url: URL
        if let recordedURL = audioURLs[track] { url = recordedURL }
        else { url = await library.audioURL(meeting, track: track) }
        let heard: Diarization, attribution: SpeakerAttribution
        if let fromRecording = recorded?[track] {
            (heard, attribution) = (fromRecording, .local(overlaps: fromRecording.overlaps))
        } else {
            (heard, attribution) = await separation(of: transcript, track: url, on: track == .remote ? .call : .room)
        }
        let current = removingDeletedSpeech(from: heard, on: track, in: meeting)
        let user = track == .me ? await claimUser(in: current) : nil
        let energy = track == .me && !current.segments.isEmpty ? micEnergy ?? speechEnergy(at: url, for: current) : nil
        let wordSpeech: [ClusterID: TimeInterval]?
        if case .transcription = attribution, let words = transcript.content.labeledWords {
            wordSpeech = Self.labeledSpeechDurations(words)
        } else {
            wordSpeech = nil
        }
        let evidence = SpeakerGate.Evidence(for: current, energy: energy, speechDurations: wordSpeech)
        let decisions = SpeakerGate().destinations(for: evidence, mode: track == .me ? .room : .call, protecting: user)
        meeting.speakers = []
        meeting.backgroundSpeakers = []
        meeting.backgroundUtterances = []
        meeting.pendingBackgroundSpeakerIDs = []
        meeting.remoteSegments = apply(current, decisions: decisions, user: user,
                                       channel: track == .me ? .room : .call, to: &meeting)
        meeting.separatedTrack = track == .me ? .me : nil
        meeting.mergedSpeakers = [:]
        meeting.attribution = attribution
        if meeting.remoteSegments.isEmpty, let first = transcript.words.first, let last = transcript.words.last {
            // No source heard anyone but STT did; keep the words under one unnamed speaker.
            let id = SpeakerID.remote(1)
            meeting.speakers = [RemoteSpeaker(id: id, label: Self.label(0), person: nil, embeddings: [])]
            meeting.remoteSegments = [SpeakerSegment(speaker: id, range: TimeRange(start: first.range.start, end: last.range.end))]
        }
        meeting.pendingPlaybackWords = nil
        meeting.micSegments = nil
        if track == .remote, !transcription.me.words.isEmpty {
            if let mic = recorded?[.me] {
                let micURL: URL
                if let recordedURL = audioURLs[.me] { micURL = recordedURL }
                else { micURL = await library.audioURL(meeting, track: .me) }
                await applyMic(mic, audio: micURL, echo: echo, energy: micEnergy, to: &meeting)
            } else {
                await separateMic(&meeting)
            }
        }
    }

    /// Without a local model, or when it throws, every mic word stays the user's.
    private func separateMic(_ meeting: inout Meeting) async {
        guard let diarizer else { return }
        let mic = await library.audioURL(meeting, track: .me), remote = await library.audioURL(meeting, track: .remote)
        let cleaned = try? micCleaner?.clean(mic: mic, remote: remote)
        defer { if let cleaned { try? FileManager.default.removeItem(at: cleaned.audio) } }
        let url = cleaned?.audio ?? mic
        guard let heard = try? await diarizer.diarize(track: url) else { return }
        await applyMic(heard, audio: url, echo: cleaned?.echo, to: &meeting)
    }

    private func speechEnergy(at url: URL, for heard: Diarization) -> SpeechEnergy? {
        try? SpeechEnergy(reading: url, through: heard.segments.map(\.range.end).max())
    }

    private func applyMic(_ diarization: Diarization, audio: URL, echo: EchoProfile?, energy: SpeechEnergy? = nil,
                          to meeting: inout Meeting) async {
        guard let transcription = meeting.transcription else { return }
        if let echo {
            let repeats = PlaybackTranscript.echoes(mic: transcription.me.words, remote: transcription.remote.words, profile: echo)
            if !repeats.isEmpty { meeting.pendingPlaybackWords = repeats }
        }
        guard !diarization.segments.isEmpty else { return }
        let heard = removingDeletedSpeech(from: diarization, on: .me, in: meeting)
        let enrollment = await voiceprints.user()?.embeddings ?? []
        let energy = energy ?? (try? SpeechEnergy(reading: audio, through: transcription.me.words.last?.range.end))
        let gate = SpeakerGate()
        let decisions: [SpeakerGate.Destination]
        if enrollment.isEmpty {
            decisions = gate.destinations(for: heard, mode: .callMic, energy: energy)
        } else {
            let evidence = SpeakerGate.Evidence(for: heard, energy: energy, measuringMicGroups: true)
            decisions = gate.callMicDestinations(for: evidence, thresholds: SpeakerGate.enrolledCallMic,
                                                userEmbeddings: enrollment, matchThresholds: thresholds)
        }
        let foreground = zip(heard.segments, decisions).compactMap { segment, decision in
            if case .foreground = decision { return segment }
            return nil
        }
        let foregroundGroups = Dictionary(grouping: foreground, by: \.cluster)
        let background = Set(decisions.compactMap { decision in
            if case .background(let id) = decision { return id }
            return nil
        })
        let played = Set(foregroundGroups.keys.filter { cluster in
            echo?.isEcho(foregroundGroups[cluster, default: []].map(\.range)) == true
        })
        if !played.isEmpty {
            meeting.transcription = Transcription(
                me: transcription.me.keeping { word in
                    // A simultaneous near-end turn must survive removal of the playback cluster.
                    let active = heard.segments.indices.filter { heard.segments[$0].range.overlap(with: word) > 0 }
                    return active.isEmpty || active.contains { index in
                        guard case .foreground(let cluster) = decisions[index] else { return true }
                        return !played.contains(cluster)
                    }
                }, remote: transcription.remote)
        }

        let clusters = Set(foregroundGroups.keys).subtracting(played)
        let mixed = clusters.intersection(background)
        var kept = heard.embeddings, brief = heard.briefEmbeddings
        if !mixed.isEmpty {
            // Do not use a voiceprint incorporating a turn that failed the loudness gate.
            let cleanVectors = try? await embedder?.voiceprints(track: audio,
                segments: foreground.filter { mixed.contains($0.cluster) }, includingBrief: true)
            for cluster in mixed {
                kept[cluster] = cleanVectors?.kept[cluster]
                brief[cluster] = cleanVectors?.brief[cluster]
            }
        }
        var mine: Set<ClusterID> = []
        if !enrollment.isEmpty {
            var similarity: [ClusterID: Double] = [:]
            for cluster in clusters {
                similarity[cluster] = await voiceprints.similarityToUser(kept[cluster] ?? brief[cluster] ?? [])
            }
            mine = Set(clusters.filter { similarity[$0].map { $0 >= thresholds.user } == true })
            if clusters.count > 1, mine.isEmpty { mine = clusters.filter { similarity[$0] == nil } }
        } else if Set(diarization.segments.map(\.cluster)).count == 1 {
            mine = clusters
        }
        let retained = zip(heard.segments, decisions).filter { _, decision in
            if case .foreground(let cluster) = decision { return !played.contains(cluster) }
            return true
        }
        let cleaned = Diarization(segments: retained.map(\.0), overlaps: heard.overlaps, embeddings: kept, briefEmbeddings: brief)
        var mic = apply(cleaned, decisions: retained.map(\.1), micUser: mine, mixed: mixed, channel: .room, to: &meeting)
        if let energy, let words = meeting.transcription?.me.words {
            let gaps = gate.quietMicGaps(words: words, turns: heard.segments.map(\.range), energy: energy)
            var next = (meeting.speakers.compactMap { Int($0.id.rawValue.dropFirst()) }.max() ?? 0) + 1
            for gap in gaps {
                let id = SpeakerID.remote(next)
                next += 1
                meeting.speakers.append(RemoteSpeaker(id: id, label: Self.label(meeting.speakers.count), person: nil, embeddings: []))
                meeting.pendingBackgroundSpeakerIDs?.append(id)
                mic.append(SpeakerSegment(speaker: id, range: gap, requiresOverlap: true))
            }
        }
        meeting.micSegments = mic.contains { $0.speaker != .me } ? mic : nil
    }

    private func removingDeletedSpeech(from heard: Diarization, on track: Track, in meeting: Meeting) -> Diarization {
        let cuts = meeting.deletedSpeakerRanges?[track] ?? []
        let shared = meeting.deletedSpeakerSharedRanges?[track] ?? []
        guard !cuts.isEmpty || !shared.isEmpty else { return heard }
        let excluded = Set(shared.compactMap { range -> Int? in
            let matches = heard.segments.indices.filter {
                heard.segments[$0].range.hasBoundaries(of: range, within: TimeRange.speakerTurnTolerance)
            }
            return matches.count == 1 ? matches.first : nil
        })
        let segments = heard.segments.enumerated().flatMap { index, segment -> [Diarization.Segment] in
            guard !excluded.contains(index) else { return [] }
            return cuts.reduce([segment.range]) { remaining, cut in
                remaining.flatMap { $0.subtracting(cut) }
            }.map { Diarization.Segment(cluster: segment.cluster, range: $0) }
        }
        return Diarization(segments: segments, overlaps: heard.overlaps,
                           embeddings: heard.embeddings, briefEmbeddings: heard.briefEmbeddings)
    }

    /// `brief` are vectors of speakers with too little clean speech to store or name anyone by.
    private func separation(of remote: TrackTranscript, track: URL, on channel: VoiceChannel) async
        -> (Diarization, SpeakerAttribution) {
        var localFailure: String?
        for source in diarizationOrder {
            switch source {
            case .local:
                guard let diarizer else { continue }
                do {
                    let diarization = try await diarizer.diarize(track: track, on: channel)
                    return (diarization, .local(overlaps: diarization.overlaps))
                } catch {
                    localFailure = String(describing: error)
                }
            case .transcription:
                guard let labeled = remote.content.labeledWords else { continue }
                let segments = Self.segments(from: labeled)
                guard let embedder else { return (Diarization(segments: segments, overlaps: [], embeddings: [:]), .transcription(voiceprintsUnavailable: .noSource)) }
                do {
                    let embeddings = try await embedder.embeddings(track: track, segments: segments)
                    return (Diarization(segments: segments, overlaps: [], embeddings: embeddings), .transcription(voiceprintsUnavailable: nil))
                } catch {
                    return (Diarization(segments: segments, overlaps: [], embeddings: [:]),
                            .transcription(voiceprintsUnavailable: .failed(reason: String(describing: error))))
                }
            }
        }
        return (Diarization(segments: [], overlaps: [], embeddings: [:]), .unseparated(localFailure.map { .failed(reason: $0) } ?? .noSource))
    }

    /// In a meeting recorded in the room, the speaker who sounds most like the enrolled user becomes
    /// `.me`, as the mic track is on a call. Below the user threshold nobody is. A speaker who
    /// said too little to store a voiceprint is judged by their brief vectors: telling the user
    /// apart needs less than naming someone, and short meetings are mostly short turns.
    private func claimUser(in heard: Diarization) async -> ClusterID? {
        var best: (id: ClusterID, similarity: Double)?
        let order = heard.segments.sorted { $0.range.start < $1.range.start }.map(\.cluster)
        var seen: Set<ClusterID> = []
        for cluster in order where seen.insert(cluster).inserted {
            let vectors = heard.embeddings[cluster] ?? heard.briefEmbeddings[cluster] ?? []
            guard let similarity = await voiceprints.similarityToUser(vectors),
                  similarity >= thresholds.user, similarity > (best?.similarity ?? -.infinity) else { continue }
            best = (cluster, similarity)
        }
        return best?.id
    }

    private func matchVoiceprints(_ meeting: inout Meeting) async {
        var suggestions: [NameSuggestion] = []
        let background = Set(meeting.pendingBackgroundSpeakerIDs ?? [])
        for index in meeting.speakers.indices {
            let speaker = meeting.speakers[index]
            guard !background.contains(speaker.id) else { continue }
            switch await voiceprints.match(speaker.embeddings, thresholds: thresholds) {
            case .autoName(let person, _):
                meeting.speakers[index].person = person
            case .suggest(let person, let similarity):
                meeting.speakers[index].person = nil
                suggestions.append(NameSuggestion(speaker: speaker.id, source: .voiceprint(person, similarity: similarity)))
            case .none:
                meeting.speakers[index].person = nil
            }
        }
        meeting.suggestions = NameSuggestions(items: suggestions)
    }

    private func align(_ meeting: inout Meeting) {
        guard let transcription = meeting.transcription else { preconditionFailure("align before transcribe") }
        let separatesMic = meeting.separatedTrack == .me
        let mic = separatesMic ? [] : Alignment.dropping(repeatsOf: transcription.remote.words, from: transcription.me.words)
        let playback = meeting.pendingPlaybackWords ?? []
        meeting.utterances = Alignment.utterances(
            me: mic.filter { !playback.contains($0) },
            remote: separatesMic ? transcription.me.words : transcription.remote.words,
            segments: meeting.remoteSegments,
            overlaps: meeting.attribution?.overlaps ?? [],
            micSegments: meeting.micSegments ?? [])
        let speaking = Set(meeting.utterances.map(\.speaker))
        let silent = Set(meeting.speakers.map(\.id) + [.me]).subtracting(speaking)
        meeting.remoteSegments.removeAll { silent.contains($0.speaker) }
        meeting.micSegments = meeting.micSegments?.filter { !silent.contains($0.speaker) }
        let background = Set(meeting.pendingBackgroundSpeakerIDs ?? [])
        meeting.backgroundSpeakers = meeting.speakers.filter { background.contains($0.id) && !silent.contains($0.id) }
        meeting.backgroundUtterances = meeting.utterances.filter { background.contains($0.speaker) }
        meeting.utterances.removeAll { background.contains($0.speaker) }
        meeting.speakers.removeAll { background.contains($0.id) || silent.contains($0.id) }
        meeting.suggestions.items.removeAll { silent.contains($0.speaker) }
        meeting.pendingPlaybackWords = nil
        meeting.pendingBackgroundSpeakerIDs = nil
        meeting.relabelSpeakers()
    }

    private func apply(_ heard: Diarization, decisions: [SpeakerGate.Destination], user: ClusterID? = nil,
                       micUser: Set<ClusterID> = [], mixed: Set<ClusterID> = [], channel: VoiceChannel, to meeting: inout Meeting) -> [SpeakerSegment] {
        var ids: [SpeakerGate.Destination: SpeakerID] = [:]
        let ordered = zip(heard.segments, decisions).enumerated().sorted {
            ($0.element.0.range.start, $0.offset) < ($1.element.0.range.start, $1.offset)
        }
        var nextID = (meeting.speakers.compactMap { Int($0.id.rawValue.dropFirst()) }.max() ?? 0) + 1
        for (_, (_, decision)) in ordered where ids[decision] == nil {
            let cluster: ClusterID, background: Bool
            switch decision {
            case .foreground(let id): (cluster, background) = (id, false)
            case .background(let id): (cluster, background) = (id, true)
            }
            if !background, cluster == user || micUser.contains(cluster) {
                ids[decision] = .me
                if cluster == user { nextID += 1 }
            } else {
                let id = SpeakerID.remote(nextID)
                nextID += 1
                let hasVectors = !background || !mixed.contains(cluster)
                ids[decision] = id
                meeting.speakers.append(RemoteSpeaker(id: id, label: Self.label(meeting.speakers.count), person: nil,
                    embeddings: hasVectors ? (heard.embeddings[cluster] ?? []).map { $0.heard(on: channel) } : [],
                    briefEmbeddings: hasVectors ? heard.briefEmbeddings[cluster]?.map { $0.heard(on: channel) } : nil))
                if background { meeting.pendingBackgroundSpeakerIDs?.append(id) }
            }
        }
        return zip(heard.segments, decisions).map { SpeakerSegment(speaker: ids[$1]!, range: $0.range) }
    }

    /// One segment per run of consecutive words sharing a label.
    private static func segments(from words: [LabeledWord]) -> [Diarization.Segment] {
        var segments: [Diarization.Segment] = []
        for labeled in words.sorted(by: { $0.word.range.start < $1.word.range.start }) {
            if let last = segments.last, last.cluster == labeled.speaker {
                segments[segments.count - 1] = .init(
                    cluster: last.cluster,
                    range: TimeRange(start: last.range.start, end: max(last.range.end, labeled.word.range.end)))
            } else {
                segments.append(.init(cluster: labeled.speaker, range: labeled.word.range))
            }
        }
        return segments
    }

    /// Count the union of word intervals for each label, independent of turns used for alignment and embeddings.
    private static func labeledSpeechDurations(_ words: [LabeledWord]) -> [ClusterID: TimeInterval] {
        Dictionary(grouping: words, by: \.speaker).mapValues { spoken in
            var end = -Double.infinity
            var seconds: TimeInterval = 0
            for range in spoken.map(\.word.range).sorted(by: { $0.start < $1.start }) {
                seconds += max(0, range.end - max(end, range.start))
                end = max(end, range.end)
            }
            return seconds
        }
    }

    private func llmTranscript(_ meeting: Meeting, language: MeetingOutputLanguage) -> LLMTranscript {
        LLMTranscript(utterances: meeting.utterances.map {
            LLMUtterance(id: $0.id, speaker: $0.speaker, range: $0.range, text: $0.text,
                         isHighlighted: meeting.isHighlighted($0))
        }, outputLanguage: language)
    }

    /// Answers a model gives in place of a name when the transcript has none.
    private static let placeholderNames: Set<String> = [
        "無", "无", "沒有", "没有", "未知", "不明", "不詳", "不详", "未提及", "無法判斷", "无法判断", "無名", "某人",
        "none", "unknown", "n/a", "na", "null", "nil", "?", "？",
    ]

    /// An inferred name has to be something said in the meeting, so a model that answers with a
    /// placeholder or invents a name gives no suggestion.
    static func isSpoken(_ name: String, in transcript: LLMTranscript) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !name.isEmpty, !placeholderNames.contains(name.lowercased()) else { return false }
        let squeezed = name.lowercased().filter { !$0.isWhitespace }
        return transcript.utterances.contains { utterance in
            utterance.text.lowercased().filter { !$0.isWhitespace }.contains(squeezed)
        }
    }

    static func label(_ index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return index < letters.count ? String(letters[index]) : "S\(index + 1)"
    }
}

extension TrackTranscript {
    /// Without the words the mic only heard because the speakers played them.
    public func dropping(_ echo: EchoProfile) -> TrackTranscript {
        switch content {
        case .unlabeled(let words):
            TrackTranscript(source: source, content: .unlabeled(echo.droppingEcho(from: words)))
        case .labeled(let words):
            TrackTranscript(source: source, content: .labeled(echo.droppingEcho(from: words, word: \.word)))
        }
    }

    func keeping(_ isKept: (TimeRange) -> Bool) -> TrackTranscript {
        switch content {
        case .unlabeled(let words):
            TrackTranscript(source: source, content: .unlabeled(words.filter { isKept($0.range) }))
        case .labeled(let words):
            TrackTranscript(source: source, content: .labeled(words.filter { isKept($0.word.range) }))
        }
    }
}
