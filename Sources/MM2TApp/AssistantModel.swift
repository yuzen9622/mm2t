import Foundation
import MM2TCore
import Observation

public struct AssistantStep: Identifiable {
    public enum Kind { case plan, search, read, answer }
    public enum State: Equatable { case running, done, failed(String), stopped }
    public let id: UUID
    public let kind: Kind
    public var arguments = AssistantArguments()
    public var result: AssistantToolResult?
    public var reasoning = ""
    public var duration: TimeInterval = 0
    public var state: State = .running
}

public struct AssistantTurn: Identifiable {
    public enum State: Equatable { case running, finished, stopped, failed(String), needsSetup }
    public let id = UUID()
    public let question: String
    public var steps: [AssistantStep] = []
    public var answer = AssistantBatcher()
    public var sources: [AssistantSource] = []
    public var state: State = .running
    public var activityExpanded = true
    public var document: AssistantMarkdown.Document {
        AssistantMarkdown.parse(answer.text, known: Set(sources.map(\.id)))
    }
    public var citedSources: [AssistantSource] {
        document.citationIDs.compactMap { id in sources.first { $0.id == id } }
    }
    public var copyText: String {
        document.runs.map { $0.citation == nil ? $0.text : "[\($0.text)]" }.joined() + (citedSources.isEmpty ? "" : "\n\n" + citedSources.enumerated().map {
            "[\($0.offset + 1)] \($0.element.title) · \(AssistantEngine.day($0.element.date))" +
                ($0.element.time.map { " · \(MeetingPresentation.timestamp($0))" } ?? "")
        }.joined(separator: "\n"))
    }
}

@MainActor @Observable
public final class AssistantModel {
    public private(set) var turns: [AssistantTurn] = []
    public var isActive = false
    public var draft = ""
    public var isRunning: Bool { turns.last?.state == .running }
    public var citedMeetings: Set<MeetingID> { Set(turns.flatMap(\.citedSources).map(\.meeting)) }
    @ObservationIgnored private let engine: AssistantEngine
    @ObservationIgnored private let build: () throws -> LLMBuild
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    public init(engine: AssistantEngine, build: @escaping () throws -> LLMBuild) {
        self.engine = engine
        self.build = build
    }
    deinit { task?.cancel(); flushTask?.cancel() }

    public static func showsPlaceholder(draft: String, hasMarkedText: Bool) -> Bool {
        draft.isEmpty && !hasMarkedText
    }

    public func send(_ question: String? = nil) {
        let question = (question ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !question.isEmpty else { return }
        draft = ""
        isActive = true
        let previous = turns.map(\.question)
        turns.append(AssistantTurn(question: question))
        let position = turns.count - 1
        do {
            guard case .ready(let provider) = try build() else { turns[position].state = .needsSetup; return }
            let events = engine.events(question: question, previous: previous, provider: provider)
            task = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled, let self, self.turns.indices.contains(position),
                          self.turns[position].state == .running else { break }
                    self.receive(event, at: position)
                }
            }
        } catch { turns[position].state = .failed(String(describing: error)) }
    }

    public func handoff(_ question: String) {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        stop()
        send(question)
    }

    public func stop() {
        guard isRunning else { return }
        task?.cancel(); task = nil
        flushTask?.cancel(); flushTask = nil
        let last = turns.count - 1
        turns[last].answer.flush(at: Date(), force: true)
        turns[last].state = .stopped
        for index in turns[last].steps.indices where turns[last].steps[index].state == .running {
            turns[last].steps[index].state = .stopped
        }
    }

    public func retry() {
        guard !isRunning, let last = turns.popLast() else { return }
        send(last.question)
    }

    public func toggleActivity(_ id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].activityExpanded.toggle()
    }

    private func receive(_ event: AssistantEvent, at index: Int) {
        switch event {
        case .planStarted:
            turns[index].steps.append(.init(id: UUID(), kind: .plan))
        case .planFinished(let reasoning, let duration):
            guard let step = turns[index].steps.firstIndex(where: { $0.kind == .plan }) else { return }
            turns[index].steps[step].reasoning = reasoning
            turns[index].steps[step].duration = duration
            turns[index].steps[step].state = .done
        case .toolStarted(let id, let kind, let arguments):
            turns[index].steps.append(.init(id: id, kind: kind == .search ? .search : .read, arguments: arguments))
        case .toolFinished(let id, let result):
            guard let step = turns[index].steps.firstIndex(where: { $0.id == id }) else { return }
            turns[index].steps[step].result = result
            turns[index].steps[step].state = .done
            turns[index].sources += result.sources
        case .answerDelta(let delta):
            turns[index].answer.append(delta)
            if flushTask == nil {
                flushTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    guard let self, self.turns.indices.contains(index), self.turns[index].state == .running else { return }
                    if self.turns[index].answer.text.isEmpty { self.turns[index].activityExpanded = false }
                    self.turns[index].answer.flush(at: Date(), force: true)
                    self.flushTask = nil
                }
            }
        case .finished(let sources):
            finish(at: index)
            turns[index].sources = sources
            turns[index].state = .finished
        case .failed(let reason):
            finish(at: index)
            turns[index].state = .failed(reason)
            turns[index].activityExpanded = true
            if let step = turns[index].steps.lastIndex(where: { $0.state == .running }) {
                turns[index].steps[step].state = .failed(reason)
            } else {
                turns[index].steps.append(.init(id: UUID(), kind: .answer, state: .failed(reason)))
            }
        }
    }

    private func finish(at index: Int) {
        flushTask?.cancel(); flushTask = nil
        let wasEmpty = turns[index].answer.text.isEmpty
        turns[index].answer.flush(at: Date(), force: true)
        if wasEmpty && !turns[index].answer.text.isEmpty { turns[index].activityExpanded = false }
    }
}
