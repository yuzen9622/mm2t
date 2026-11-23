import Foundation
import MM2TCore
import MM2TProviders
import Observation

/// Where one meeting stands in this app session. The meeting document's own `status` is the
/// durable record; this adds what only the running app knows (queued, running, waiting for setup).
public enum JobState: Equatable, Sendable {
    case queued
    /// nil until the pipeline reports its first step.
    case running(ProcessingStep?)
    /// Processing never started because something must be configured first.
    case needsSetup([SetupIssue])
    /// `step` is nil when the failure happened outside a pipeline step (e.g. reading the Keychain).
    case failed(step: ProcessingStep?, reason: String)
    case completed

    public var isActive: Bool {
        switch self {
        case .queued, .running: true
        default: false
        }
    }
}

/// What a job asks the pipeline to do.
public enum ProcessingOperation: Sendable {
    /// Run from the meeting's resume step: a new recording, or a retry after a failure.
    case process
    /// Name inference and the three generated views again, after speakers changed.
    case regenerate
    /// Speaker separation, voiceprints and alignment again, on the stored transcription.
    case reseparate
}

/// Runs pipeline jobs one at a time, since each loads the on-device models and uploads audio.
@MainActor @Observable
public final class ProcessingQueue {
    public private(set) var jobs: [MeetingID: JobState] = [:]
    /// Bumped whenever a meeting document may have changed, so open views reload.
    public private(set) var revision = 0

    /// Called with each meeting a job finished processing.
    @ObservationIgnored public var onCompleted: (@MainActor (Meeting) -> Void)?
    @ObservationIgnored private let makePipeline: @MainActor () throws -> PipelineBuild
    @ObservationIgnored private let makeLLM: @MainActor () throws -> LLMBuild
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var running: (id: MeetingID, token: UUID)?
    @ObservationIgnored private var tasks: [MeetingID: (token: UUID, task: Task<Void, Never>)] = [:]

    public init(makePipeline: @escaping @MainActor () throws -> PipelineBuild,
                makeLLM: @escaping @MainActor () throws -> LLMBuild) {
        self.makePipeline = makePipeline
        self.makeLLM = makeLLM
    }

    /// Rewrites a passage with the configured large language model, outside any job: it changes nothing
    /// until the user saves the result.
    public func rewrite(_ text: String, instruction: String) async throws -> String {
        guard case .ready(let pipeline) = try makePipeline() else { throw RewriteUnsupported() }
        return try await pipeline.llm.rewrite(text, instruction: instruction)
    }

    /// Only the passage explicitly corrected by the user is sent to the selected model.
    public func vocabularyCorrections(from old: String, to new: String) async throws -> [VocabularyCorrection] {
        guard case .ready(let llm) = try makeLLM() else { return [] }
        return try await llm.vocabularyCorrections(from: old, to: new)
    }

    /// Everything waiting on setup, deduplicated, in first-seen order.
    public var pendingSetup: [SetupIssue] {
        var seen: [SetupIssue] = []
        for state in jobs.values {
            if case .needsSetup(let issues) = state {
                for issue in issues where !seen.contains(issue) { seen.append(issue) }
            }
        }
        return seen
    }

    public var activeJob: (id: MeetingID, state: JobState)? {
        if let running, let state = jobs[running.id] { return (running.id, state) }
        return jobs.first { $0.value.isActive }.map { ($0.key, $0.value) }
    }

    public func isBusy(_ id: MeetingID) -> Bool { jobs[id]?.isActive ?? false }

    /// Returns when this job (and every job queued before it) has finished.
    public func run(_ operation: ProcessingOperation, on id: MeetingID, using prepared: MeetingProcessingPipeline? = nil,
                    whileValid: @escaping @MainActor @Sendable () async -> Bool = { true }) async {
        await enqueue(operation, on: id, using: prepared, whileValid: whileValid)?.value
    }

    /// Claims the meeting synchronously, before capture exposes its ID to the views.
    /// Recording finalization can make its transcript readable while another meeting runs.
    func enqueue(_ operation: ProcessingOperation, on id: MeetingID, using prepared: MeetingProcessingPipeline? = nil,
                 finalize: (@MainActor @Sendable () async -> Void)? = nil,
                 whileValid: @escaping @MainActor @Sendable () async -> Bool = { true }) -> Task<Void, Never>? {
        guard !isBusy(id) else { return nil }
        jobs[id] = finalize == nil ? .queued : .running(.transcribe)
        revision += 1
        let previous = tail
        let token = UUID()
        let task = Task { @MainActor in
            await HostedRequestGroup.$current.withValue(token) {
                defer {
                    if self.tasks[id]?.token == token {
                        self.tasks[id] = nil
                        if Task.isCancelled, self.jobs[id]?.isActive == true { self.jobs[id] = nil }
                        self.revision += 1
                    }
                }
                if let finalize {
                    await finalize()
                    if Task.isCancelled {
                        if self.tasks[id]?.token == token {
                            self.tasks[id] = nil
                            self.jobs[id] = nil
                        }
                    } else {
                        self.jobs[id] = .queued
                    }
                    self.revision += 1
                }
                await previous?.value
                guard !Task.isCancelled else { return }
                let current = await whileValid()
                guard !Task.isCancelled else { return }
                await self.execute(operation, on: id, using: current ? prepared : nil)
            }
        }
        tasks[id] = (token, task)
        tail = task
        return task
    }

    /// Stops a queued or running job. The meeting keeps its audio and every finished step, and
    /// waits as not processed until the user processes it again. A queued job leaves the queue at
    /// once; its place in line only ends when the job ahead of it does.
    public func cancel(_ id: MeetingID) {
        guard let entry = tasks[id] else { return }
        entry.task.cancel()
        if jobs[id] == .queued {
            tasks[id] = nil
            jobs[id] = nil
            revision += 1
        }
    }

    /// Retries every meeting that was waiting on setup.
    public func retryAfterSetup() async {
        let waiting = jobs.filter { if case .needsSetup = $0.value { true } else { false } }.map(\.key)
        await withTaskGroup(of: Void.self) { group in
            for id in waiting { group.addTask { await self.run(.process, on: id) } }
        }
    }

    private func execute(_ operation: ProcessingOperation, on id: MeetingID, using prepared: MeetingProcessingPipeline?) async {
        let pipeline: MeetingProcessingPipeline
        do {
            switch try prepared.map(PipelineBuild.ready) ?? makePipeline() {
            case .ready(let ready): pipeline = ready
            case .needsSetup(let issues):
                jobs[id] = .needsSetup(issues)
                return
            }
        } catch {
            jobs[id] = .failed(step: nil, reason: String(describing: error))
            return
        }

        let token = UUID()
        running = (id, token)
        defer { running = nil }
        jobs[id] = .running(nil)
        let progress: @Sendable (ProcessingStep) -> Void = { [weak self] step in
            Task { @MainActor in self?.progressed(id, step, token) }
        }
        do {
            let meeting: Meeting
            switch operation {
            case .process: meeting = try await pipeline.process(id, progress: progress)
            case .regenerate: meeting = try await pipeline.regenerateLLMOutputs(id, progress: progress)
            case .reseparate:
                jobs[id] = .running(.diarize)
                meeting = try await pipeline.reseparateSpeakers(id)
            }
            switch meeting.status {
            case .completed:
                jobs[id] = .completed
                onCompleted?(meeting)
            case .failed(let step, let reason): jobs[id] = .failed(step: step, reason: reason)
            case .pending(let step): jobs[id] = .failed(step: step, reason: "processing stopped before \(step.rawValue)")
            }
        } catch is CancellationError {
            jobs[id] = nil
        } catch {
            jobs[id] = .failed(step: nil, reason: String(describing: error))
        }
        revision += 1
    }

    /// Progress arrives on separate tasks, so one can land after the job finished; only the
    /// job that is still running with the same token may take it.
    private func progressed(_ id: MeetingID, _ step: ProcessingStep, _ token: UUID) {
        guard running?.id == id, running?.token == token, case .running = jobs[id] else { return }
        jobs[id] = .running(step)
        revision += 1
    }

    /// Forgets a deleted meeting.
    public func remove(_ id: MeetingID) {
        guard !isBusy(id) else { return }
        jobs[id] = nil
    }
}
