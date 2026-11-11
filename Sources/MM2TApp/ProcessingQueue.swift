import Foundation
import MM2TCore
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

    /// Called with each meeting a job finished processing, e.g. to learn its vocabulary.
    @ObservationIgnored public var onCompleted: (@MainActor (Meeting) -> Void)?
    @ObservationIgnored private let makePipeline: @MainActor () throws -> PipelineBuild
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var running: (id: MeetingID, token: UUID)?

    public init(makePipeline: @escaping @MainActor () throws -> PipelineBuild) {
        self.makePipeline = makePipeline
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
    public func run(_ operation: ProcessingOperation, on id: MeetingID) async {
        guard !isBusy(id) else { return }
        jobs[id] = .queued
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await self.execute(operation, on: id)
        }
        tail = task
        await task.value
    }

    /// Retries every meeting that was waiting on setup.
    public func retryAfterSetup() async {
        let waiting = jobs.filter { if case .needsSetup = $0.value { true } else { false } }.map(\.key)
        await withTaskGroup(of: Void.self) { group in
            for id in waiting { group.addTask { await self.run(.process, on: id) } }
        }
    }

    private func execute(_ operation: ProcessingOperation, on id: MeetingID) async {
        let pipeline: MeetingProcessingPipeline
        do {
            switch try makePipeline() {
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
