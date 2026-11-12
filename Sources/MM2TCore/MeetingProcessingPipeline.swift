import Foundation

public enum SpeakerSeparationError: Error, Equatable {
    /// Re-running separation needs a finished meeting; a failed one resumes with `process` instead.
    case meetingNotCompleted(ProcessingStatus)
}

/// Turns a recorded meeting into a transcript with speakers and LLM outputs.
/// Every step persists its result before the next starts, so a retry resumes at the failed step.
public struct MeetingProcessingPipeline: Sendable {
    public let library: MeetingLibrary
    public let voiceprints: VoiceprintStore
    public let diarizer: (any Diarizer)?
    public let embedder: (any SpeakerEmbedder)?
    /// Sources tried in order for the remote track's speaker turns.
    public let diarizationOrder: [DiarizationSource]
    public let transcription: TranscriptionChain
    public let llm: any LLMProvider
    public let thresholds: MatchThresholds
    public let vocabulary: [String]
    /// Whether the two tracks are transcribed at once, and name inference and the three generated
    /// views written at once. Right for hosted services; an on-device model has one set of weights.
    public let runsConcurrently: Bool
    /// Removes the speakers' echo of the remote track from the mic track before it is transcribed
    /// and separated. nil leaves the mic as recorded.
    public let micCleaner: (any MicCleaner)?

    public init(
        library: MeetingLibrary,
        voiceprints: VoiceprintStore,
        diarizer: (any Diarizer)?,
        embedder: (any SpeakerEmbedder)?,
        diarizationOrder: [DiarizationSource] = [.local, .transcription],
        transcription: TranscriptionChain,
        llm: any LLMProvider,
        thresholds: MatchThresholds,
        vocabulary: [String],
        runsConcurrently: Bool = false,
        micCleaner: (any MicCleaner)? = nil
    ) {
        self.runsConcurrently = runsConcurrently
        self.micCleaner = micCleaner
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

    /// Runs from the meeting's resume step to the end. A step failure is recorded in
    /// `meeting.status` and returned, not thrown; only persistence errors throw.
    @discardableResult
    public func process(
        _ id: MeetingID,
        progress: @Sendable (ProcessingStep) -> Void = { _ in }
    ) async throws -> Meeting {
        var meeting = try await library.meeting(id)
        if case .failed(let step, _) = meeting.status {
            meeting.status = .pending(next: step)
            try await library.save(meeting)
        }
        while let step = meeting.status.resumeStep {
            if runsConcurrently, step >= .inferNames {
                // One label for the group: the summary is the part the user is waiting for.
                progress(.summarize)
                try await generate(from: step, on: &meeting)
                return meeting
            }
            progress(step)
            do {
                try await run(step, on: &meeting)
                meeting.status = step.next.map { .pending(next: $0) } ?? .completed
            } catch {
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
    private func generate(from first: ProcessingStep, on meeting: inout Meeting) async throws {
        let steps = ProcessingStep.allCases.filter { $0 >= first }
        let start = meeting
        var failures: [ProcessingStep: String] = [:]
        await withTaskGroup(of: (ProcessingStep, Result<Meeting, any Error>).self) { group in
            for step in steps {
                group.addTask {
                    var copy = start
                    do {
                        try await run(step, on: &copy)
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
        if let failed = steps.first(where: { failures[$0] != nil }) {
            meeting.status = .failed(step: failed, reason: failures[failed]!)
        } else {
            meeting.status = .completed
        }
        try await library.save(meeting)
    }

    /// Copies what `step` wrote, leaving what the other concurrent steps wrote in place.
    private func merge(_ step: ProcessingStep, from done: Meeting, into meeting: inout Meeting) {
        switch step {
        case .inferNames: meeting.suggestions = done.suggestions
        case .cleanTranscript: meeting.outputs.cleaned = done.outputs.cleaned
        case .digestPerPerson: meeting.outputs.digests = done.outputs.digests
        case .summarize:
            meeting.outputs.summary = done.outputs.summary
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

    private func run(_ step: ProcessingStep, on meeting: inout Meeting) async throws {
        switch step {
        case .transcribe:
            let names = await voiceprints.spokenNames()
            let hints = names + vocabulary.filter { !names.contains($0) }
            let micURL = await library.audioURL(meeting, track: .me), remoteURL = await library.audioURL(meeting, track: .remote)
            let cleaned = try? micCleaner?.clean(mic: micURL, remote: remoteURL)
            defer { if let cleaned { try? FileManager.default.removeItem(at: cleaned.audio) } }
            let heardURL = cleaned?.audio ?? micURL
            let remote: TrackTranscript
            var me: TrackTranscript
            if runsConcurrently {
                // Both at once, so the mic is labeled before anyone knows whether it needs to be.
                async let remoteTask = transcription.transcribe(audio: remoteURL, hints: hints, labelSpeakers: true)
                async let meTask = transcription.transcribe(audio: heardURL, hints: hints, labelSpeakers: true)
                (remote, me) = try await (remoteTask, meTask)
            } else {
                remote = try await transcription.transcribe(audio: remoteURL, hints: hints, labelSpeakers: true)
                // A silent remote track means the meeting happened in the room, so the mic holds every
                // voice and is the track whose speakers need telling apart.
                me = try await transcription.transcribe(audio: heardURL, hints: hints, labelSpeakers: remote.words.isEmpty)
            }
            if let echo = cleaned?.echo { me = me.dropping(echo) }
            meeting.transcription = Transcription(me: me.inTraditionalChinese, remote: remote.inTraditionalChinese)

        case .diarize:
            await diarize(&meeting)

        case .matchVoiceprints:
            await matchVoiceprints(&meeting)

        case .align:
            align(&meeting)

        case .inferNames:
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
                let guesses = try await llm.inferNames(NameInferenceRequest(
                    transcript: llmTranscript(meeting), unnamedSpeakers: unnamed, knownNames: known))
                inferred = guesses
                    .filter { unnamed.contains($0.speaker) && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map { NameSuggestion(speaker: $0.speaker, source: .inferred(
                        name: TraditionalChinese.convert($0.name), reason: TraditionalChinese.convert($0.reason))) }
            }
            meeting.suggestions = NameSuggestions(items: voiceprintSuggestions + inferred)

        case .cleanTranscript:
            var transcript = llmTranscript(meeting)
            let names = await voiceprints.spokenNames()
            transcript.glossary = names + vocabulary.filter { !names.contains($0) }
            meeting.outputs.cleaned = try await llm.cleanTranscript(transcript).inTraditionalChinese

        case .digestPerPerson:
            meeting.outputs.digests = try await llm.digestPerPerson(llmTranscript(meeting)).map(\.inTraditionalChinese)

        case .summarize:
            let transcript = llmTranscript(meeting)
            let summary = try await llm.summarize(SummaryRequest(
                transcript: transcript,
                prioritized: transcript.utterances.filter(\.isHighlighted))).inTraditionalChinese
            meeting.outputs.summary = summary
            meeting.outputs.isStale = false
            // The recorder can only name a meeting after its app ("Google Meet") or "Recording".
            if let title = summary.title, !meeting.metadata.isTitleEdited { meeting.metadata.title = title }
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
    private func diarize(_ meeting: inout Meeting) async {
        guard let transcription = meeting.transcription else { preconditionFailure("diarize before transcribe") }
        let track: Track = transcription.remote.words.isEmpty && !transcription.me.words.isEmpty ? .me : .remote
        let remote = track == .me ? transcription.me : transcription.remote
        let separated = await separation(of: remote, track: library.audioURL(meeting, track: track))
        let channel: VoiceChannel = track == .me ? .room : .call
        let ids = apply(separated.segments, embeddings: separated.embeddings.mapValues { $0.map { $0.heard(on: channel) } },
                        to: &meeting)
        let attribution = separated.attribution
        meeting.separatedTrack = track == .me ? .me : nil
        meeting.mergedSpeakers = [:]
        meeting.attribution = attribution
        if meeting.remoteSegments.isEmpty, let first = remote.words.first, let last = remote.words.last {
            // No source heard anyone but STT did; keep the words under one unnamed speaker.
            let id = SpeakerID.remote(1)
            meeting.speakers = [RemoteSpeaker(id: id, label: Self.label(0), person: nil, embeddings: [])]
            meeting.remoteSegments = [SpeakerSegment(speaker: id, range: TimeRange(start: first.range.start, end: last.range.end))]
        }
        meeting.micSegments = nil
        if track == .remote, !transcription.me.words.isEmpty { await separateMic(&meeting) }
        if track == .me {
            let brief = Dictionary(separated.brief.compactMap { cluster, vectors in ids[cluster].map { ($0, vectors) } },
                                   uniquingKeysWith: +)
            await claimUser(in: &meeting, brief: brief)
        }
    }

    /// On a call the mic is the user's own, but in a shared room it hears the people next to them
    /// and, without headphones, the call itself. A voice that mostly went away with the echo was the
    /// speakers, and its words are dropped. Of the rest, the user is whoever sounds like their
    /// enrollment and every other voice becomes a speaker of its own. Without a local model, or
    /// when it throws, every mic word stays the user's.
    private func separateMic(_ meeting: inout Meeting) async {
        guard let diarizer, let transcription = meeting.transcription else { return }
        let enrolled = await voiceprints.user() != nil
        let mic = await library.audioURL(meeting, track: .me), remote = await library.audioURL(meeting, track: .remote)
        let cleaned = try? micCleaner?.clean(mic: mic, remote: remote)
        defer { if let cleaned { try? FileManager.default.removeItem(at: cleaned.audio) } }
        guard enrolled || cleaned != nil,
              let heard = try? await diarizer.diarize(track: cleaned?.audio ?? mic) else { return }

        var clusters: [ClusterID] = []
        for segment in heard.segments.sorted(by: { $0.range.start < $1.range.start })
        where !clusters.contains(segment.cluster) {
            clusters.append(segment.cluster)
        }
        if let echo = cleaned?.echo {
            let played = Set(clusters.filter { cluster in
                echo.isEcho(heard.segments.filter { $0.cluster == cluster }.map(\.range))
            })
            if !played.isEmpty {
                meeting.transcription = Transcription(
                    me: transcription.me.keeping { word in
                        let voice = heard.segments.max { $0.range.overlap(with: word) < $1.range.overlap(with: word) }
                        return voice.map { $0.range.overlap(with: word) == 0 || !played.contains($0.cluster) } ?? true
                    },
                    remote: transcription.remote)
                clusters.removeAll(where: played.contains)
            }
        }
        guard clusters.count > 1 else { return }
        // Only the voiceprint says who the user is. Once a voice matches, every other voice is
        // someone else. With no match, a voice that scored below the threshold is someone else and
        // one with no vector at all stays the user's, as nothing tells it apart.
        var similarity: [ClusterID: Double] = [:]
        for cluster in clusters {
            let vectors = heard.embeddings[cluster] ?? heard.briefEmbeddings[cluster] ?? []
            similarity[cluster] = await voiceprints.similarityToUser(vectors)
        }
        let mine = Set(clusters.filter { similarity[$0].map { $0 >= thresholds.user } == true })
        var others: [ClusterID: SpeakerID] = [:]
        for cluster in clusters where !mine.contains(cluster) && (!mine.isEmpty || similarity[cluster] != nil) {
            let id = SpeakerID.remote(meeting.speakers.count + 1)
            meeting.speakers.append(RemoteSpeaker(
                id: id, label: Self.label(meeting.speakers.count), person: nil,
                embeddings: (heard.embeddings[cluster] ?? []).map { $0.heard(on: .room) }))
            others[cluster] = id
        }
        guard !others.isEmpty else { return }
        meeting.micSegments = heard.segments.filter { clusters.contains($0.cluster) }
            .map { SpeakerSegment(speaker: others[$0.cluster] ?? .me, range: $0.range) }
    }

    /// `brief` are vectors of speakers with too little clean speech to store or name anyone by.
    private func separation(of remote: TrackTranscript, track: URL) async
        -> (segments: [Diarization.Segment], embeddings: [ClusterID: [Embedding]], brief: [ClusterID: [Embedding]],
            attribution: SpeakerAttribution) {
        var localFailure: String?
        for source in diarizationOrder {
            switch source {
            case .local:
                guard let diarizer else { continue }
                do {
                    let diarization = try await diarizer.diarize(track: track)
                    return (diarization.segments, diarization.embeddings, diarization.briefEmbeddings,
                            .local(overlaps: diarization.overlaps))
                } catch {
                    localFailure = String(describing: error)
                }
            case .transcription:
                guard let labeled = remote.content.labeledWords else { continue }
                let segments = Self.segments(from: labeled)
                guard let embedder else { return (segments, [:], [:], .transcription(voiceprintsUnavailable: .noSource)) }
                do {
                    let embeddings = try await embedder.embeddings(track: track, segments: segments)
                    return (segments, embeddings, [:], .transcription(voiceprintsUnavailable: nil))
                } catch {
                    return (segments, [:], [:], .transcription(voiceprintsUnavailable: .failed(reason: String(describing: error))))
                }
            }
        }
        return ([], [:], [:], .unseparated(localFailure.map { .failed(reason: $0) } ?? .noSource))
    }

    /// In a meeting recorded in the room, the speaker who sounds most like the enrolled user becomes
    /// `.me`, as the mic track is on a call. Below the user threshold nobody is. A speaker who
    /// said too little to store a voiceprint is judged by their `brief` vectors: telling the user
    /// apart needs less than naming someone, and short meetings are mostly short turns.
    private func claimUser(in meeting: inout Meeting, brief: [SpeakerID: [Embedding]]) async {
        var best: (id: SpeakerID, similarity: Double)?
        for speaker in meeting.speakers {
            let vectors = speaker.embeddings.isEmpty ? brief[speaker.id] ?? [] : speaker.embeddings
            guard let similarity = await voiceprints.similarityToUser(vectors),
                  similarity >= thresholds.user, similarity > (best?.similarity ?? -.infinity) else { continue }
            best = (speaker.id, similarity)
        }
        guard let mine = best?.id else { return }
        meeting.remoteSegments = meeting.remoteSegments.map {
            $0.speaker == mine ? SpeakerSegment(speaker: .me, range: $0.range) : $0
        }
        meeting.speakers = meeting.speakers.filter { $0.id != mine }.enumerated().map { index, speaker in
            RemoteSpeaker(id: speaker.id, label: Self.label(index), person: speaker.person, embeddings: speaker.embeddings)
        }
    }

    private func matchVoiceprints(_ meeting: inout Meeting) async {
        var suggestions: [NameSuggestion] = []
        for index in meeting.speakers.indices {
            let speaker = meeting.speakers[index]
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
        meeting.utterances = Alignment.utterances(
            me: separatesMic ? [] : Alignment.dropping(repeatsOf: transcription.remote.words, from: transcription.me.words),
            remote: separatesMic ? transcription.me.words : transcription.remote.words,
            segments: meeting.remoteSegments,
            overlaps: meeting.attribution?.overlaps ?? [],
            micSegments: meeting.micSegments ?? [])
        // Someone the mic heard whose every word turned out to be echo said nothing.
        let speaking = Set(meeting.utterances.map(\.speaker))
        let micOnly = Set((meeting.micSegments ?? []).map(\.speaker)).subtracting(meeting.remoteSegments.map(\.speaker))
        let silent = micOnly.subtracting(speaking)
        meeting.micSegments = meeting.micSegments?.filter { !silent.contains($0.speaker) }
        meeting.speakers = meeting.speakers.filter { !silent.contains($0.id) }
            .enumerated().map { index, speaker in
                RemoteSpeaker(id: speaker.id, label: Self.label(index), person: speaker.person, embeddings: speaker.embeddings)
            }
    }

    @discardableResult
    private func apply(_ segments: [Diarization.Segment], embeddings: [ClusterID: [Embedding]],
                       to meeting: inout Meeting) -> [ClusterID: SpeakerID] {
        var order: [ClusterID] = []
        for segment in segments.sorted(by: { $0.range.start < $1.range.start })
        where !order.contains(segment.cluster) {
            order.append(segment.cluster)
        }
        let ids = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, SpeakerID.remote($0 + 1)) })
        meeting.speakers = order.enumerated().map { index, cluster in
            RemoteSpeaker(id: ids[cluster]!, label: Self.label(index), person: nil,
                          embeddings: embeddings[cluster] ?? [])
        }
        meeting.remoteSegments = segments.map { SpeakerSegment(speaker: ids[$0.cluster]!, range: $0.range) }
        return ids
    }

    /// One segment per run of consecutive words sharing a label.
    static func segments(from words: [LabeledWord]) -> [Diarization.Segment] {
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

    private func llmTranscript(_ meeting: Meeting) -> LLMTranscript {
        LLMTranscript(utterances: meeting.utterances.map {
            LLMUtterance(id: $0.id, speaker: $0.speaker, range: $0.range, text: $0.text,
                         isHighlighted: meeting.isHighlighted($0))
        })
    }

    static func label(_ index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return index < letters.count ? String(letters[index]) : "S\(index + 1)"
    }
}

extension TrackTranscript {
    /// Without the words the mic only heard because the speakers played them.
    public func dropping(_ echo: EchoProfile) -> TrackTranscript {
        keeping { !echo.isEcho($0) }
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
