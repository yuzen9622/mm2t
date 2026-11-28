import Foundation
import MM2TCore
import MM2TProviders
import Observation

public struct AssistantStep: Identifiable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case plan, search, read, tasks, filing, answer }
    public enum State: Codable, Equatable, Sendable { case running, done, failed(String), stopped }
    public let id: UUID
    public let kind: Kind
    public var arguments = AssistantArguments()
    public var result: AssistantToolResult?
    public var reasoning = ""
    public var duration: TimeInterval = 0
    public var state: State = .running
}

public struct AssistantTurn: Identifiable, Codable, Sendable {
    public enum State: Codable, Equatable, Sendable { case running, finished, stopped, failed(String), needsSetup }
    public var id = UUID()
    public var createdAt = Date()
    public var memoryRevision: UUID?
    public var scope: Set<MeetingID>?
    public var folderBatch: UUID?
    public var folderProposals: [FolderProposal]?
    public var memoryProposal: String?
    public var memoryManagement = false
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
    public private(set) var ledger = AssistantLedger()
    public private(set) var conversationID = UUID()
    public private(set) var storageError: String?
    public let conversations: AssistantConversations?
    public let preferences: AssistantPreferences?
    @ObservationIgnored private let owner = UUID()
    @ObservationIgnored private var lastCheckpoint = Date.distantPast
    @ObservationIgnored private var attached = true
    public var isActive = false
    public var draftReferences: Set<MeetingID> = []
    public var draft = ""
    public var scroll = AssistantFollowScroll()
    public var shownContent = AssistantShownContent()
    public var isRunning: Bool { turns.last?.state == .running }
    public var citedMeetings: Set<MeetingID> { Set(turns.flatMap(\.citedSources).map(\.meeting)) }
    @ObservationIgnored private let engine: AssistantEngine
    @ObservationIgnored private let build: () throws -> LLMBuild
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    public init(engine: AssistantEngine, conversations: AssistantConversations? = nil,
                preferences: AssistantPreferences? = nil, build: @escaping () throws -> LLMBuild) {
        self.engine = engine
        self.build = build
        self.conversations = conversations
        self.preferences = preferences
        if let conversations {
            do { restore(try conversations.open(conversations.availableRecent(), owner: owner)) }
            catch { storageError = String(describing: error) }
        }
        observePreferences()
    }
    deinit {
        task?.cancel(); flushTask?.cancel()
        let store = conversations, lease = owner
        Task { @MainActor in store?.release(owner: lease) }
    }

    private var record: AssistantConversation {
        var value = AssistantConversation()
        value.id = conversationID; value.turns = turns; value.ledger = ledger
        return value
    }

    @discardableResult public func save() -> Bool {
        guard let conversations, attached, !turns.isEmpty else { return true }
        do { try conversations.save(record, owner: owner); storageError = nil; lastCheckpoint = Date(); return true }
        catch { storageError = String(describing: error); return false }
    }

    public func newConversation() { openConversation(nil) }

    public func openConversation(_ id: UUID?) {
        stop()
        guard save() else { return }
        do {
            let next = try conversations?.open(id, owner: owner) ?? AssistantConversation()
            if conversationID != next.id { conversations?.release(conversationID, owner: owner) }
            restore(next)
            attached = true
            isActive = true
            draft = ""; shownContent = .init()
            shownContent.settleAnswers(turns)
        } catch { storageError = String(describing: error) }
    }

    private func restore(_ record: AssistantConversation) {
        draftReferences = []
        conversationID = record.id; turns = record.turns; ledger = record.ledger
        storageError = conversations?.isUnsaved(record.id) == true ? "Unsaved conversation recovered in memory. Retry saving before closing." : nil
        isActive = !turns.isEmpty
        scroll = .opening(turns)
        shownContent.settleAnswers(turns)
    }

    public func undoFiling(_ turn: UUID) {
        guard let i = turns.firstIndex(where: { $0.id == turn }), let batch = turns[i].folderBatch else { return }
        engine.folders?.undo(batchID: batch); turns[i].folderBatch = nil; save()
    }
    public enum FilingApproval: Error { case changed, saveFailed }

    public func filingPreview(_ name: String, turn: UUID) async throws -> [FolderProposal.Row] {
        guard let proposal = turns.first(where: { $0.id == turn })?.folderProposals?.first(where: { $0.name == name }),
              engine.folders?.canApply(proposal) == true else { throw FilingApproval.changed }
        return try await engine.library.filingRows(for: proposal.meetings)
    }

    public func approveFiling(_ name: String, turn: UUID, preview: [FolderProposal.Row]) async throws {
        let current = try await filingPreview(name, turn: turn)
        guard preview == current, !Task.isCancelled, let folders = engine.folders,
              let i = turns.firstIndex(where: { $0.id == turn }),
              let proposal = turns[i].folderProposals?.first(where: { $0.name == name }),
              proposal.meetings == current.map(\.id), folders.canApply(proposal) else { throw FilingApproval.changed }
        guard let batch = folders.apply(proposal, joining: turns[i].folderBatch) else { throw FilingApproval.saveFailed }
        turns[i].folderBatch = batch
        dismissFiling(name, turn: turn)
    }

    public func dismissFiling(_ name: String, turn: UUID) {
        guard let i = turns.firstIndex(where: { $0.id == turn }) else { return }
        turns[i].folderProposals?.removeAll { $0.name == name }
        save()
    }

    public func confirmPreference(turn id: UUID, text: String) {
        guard !isRunning, let index = turns.firstIndex(where: { $0.id == id }), turns[index].memoryProposal != nil else { return }
        do {
            try preferences?.put(text: text, sourceTurn: id)
            turns[index].memoryProposal = nil
            save()
        } catch { storageError = String(describing: error) }
    }

    public func dismissPreference(turn id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].memoryProposal = nil; save()
    }

    private func observePreferences() {
        withObservationTracking { _ = preferences?.revision } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isRunning, self.turns.last?.memoryRevision != self.preferences?.revision { self.stop() }
                for index in self.turns.indices where self.turns[index].memoryRevision != self.preferences?.revision {
                    self.turns[index].memoryProposal = nil
                }
                self.save()
                self.observePreferences()
            }
        }
    }

    public static func showsPlaceholder(draft: String, hasMarkedText: Bool) -> Bool {
        draft.isEmpty && !hasMarkedText
    }

    public func send(_ question: String? = nil) {
        let question = (question ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !question.isEmpty else { return }
        let references = draftReferences
        draft = ""
        isActive = true
        if !attached {
            let saved = conversations?.records.contains { $0.id == conversationID } == true
            openConversation(saved ? conversationID : nil)
            guard attached else { return }
        }
        let revision = preferences?.revision
        let previousScope = turns.last?.scope
        let scope = references.isEmpty ? previousScope : references
        draftReferences = []
        var scopedRecord = record
        scopedRecord.turns = scopedRecord.turns.filter { $0.scope == scope }
        if scope != turns.last?.scope { ledger = .init() }
        let history = scopedRecord.history(memoryRevision: revision)
        turns.append(AssistantTurn(memoryRevision: revision, scope: scope, question: question))
        let position = turns.count - 1
        let turnID = turns[position].id
        scroll = position == 0 ? .top : .init(holding: turnID)
        save()
        do {
            guard case .ready(let provider) = try build() else { turns[position].state = .needsSetup; save(); return }
            let shouldPropose = preferences?.enabled == true && preferences?.error == nil && question.count <= 3_000
            let preferenceContext = preferences?.context(for: question) ?? ""
            let currentLedger = ledger
            task = Task { [weak self] in
                await HostedRequestGroup.$current.withValue(UUID()) {
                    if shouldPropose {
                        let proposal = try? await assistantTimeout(seconds: 30) {
                            try await AssistantGeneration.memoryProposal(provider: provider, question: question)
                        }
                        guard !Task.isCancelled, let self, self.preferences?.revision == revision,
                              self.turns.indices.contains(position), self.turns[position].id == turnID else { return }
                        if let proposal {
                            self.turns[position].memoryProposal = proposal
                            self.turns[position].memoryManagement = true
                            self.save()
                        }
                    }
                    guard !Task.isCancelled, let self else { return }
                    var effectiveScope = scope
                    let mergeRequested = question.range(of: #"(?:也算上|也包含|加上|合併|連同|一起比較|也納入).{0,12}(?:先前|之前|剛才|前面|上次|前.{0,2}場)|(?:include|combine|along with).{0,24}(?:previous|earlier|prior)"#, options: [.regularExpression, .caseInsensitive]) != nil
                    let widerSearchRequested = question.range(of: #"(?:再找|搜[尋索]?|擴大|也查|找找|查一下).{0,16}(?:更早|其他|其它|全部|所有|範圍)|(?:search|look|find).{0,30}(?:other|earlier|all meetings|outside)"#, options: [.regularExpression, .caseInsensitive]) != nil
                    if let previousScope, (mergeRequested || widerSearchRequested), let rule = try? await AssistantGeneration.userDirective(provider: provider, question: question, rule: "Scope of referenced meetings: keep unless the user explicitly asks to search outside, earlier or other meetings (expand); merge only when the user explicitly asks to include previously referenced meetings along with new references. A generic follow-up never expands scope.", choices: ["keep", "expand", "merge"]) {
                        if widerSearchRequested && rule == "expand" { effectiveScope = nil }
                        if mergeRequested && rule == "merge" { effectiveScope = previousScope.union(references) }
                    }
                    guard !Task.isCancelled, self.turns.indices.contains(position), self.turns[position].id == turnID else { return }
                    self.turns[position].scope = effectiveScope
                    let events = self.engine.events(question: question, provider: provider, history: history,
                        preferences: preferenceContext, ledger: currentLedger, scope: effectiveScope, explicitReferences: references)
                    for await event in events {
                        guard !Task.isCancelled, self.turns.indices.contains(position),
                              self.turns[position].id == turnID, self.preferences?.revision == revision,
                              self.turns[position].state == .running else { break }
                        self.receive(event, at: position)
                    }
                }
            }
        } catch { turns[position].state = .failed(String(describing: error)); save() }
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
        save()
    }

    public func pageDisappeared() {
        shownContent.settleAnswers(turns)
    }

    public func close() {
        stop()
        guard save() else { return }
        conversations?.release(conversationID, owner: owner)
        attached = false
        if conversations == nil { turns = []; ledger = .init() }
        isActive = false
        draft = ""
        scroll = AssistantFollowScroll()
        shownContent = AssistantShownContent()
    }

    public func retry() {
        guard !isRunning, let last = turns.popLast() else { return }
        draftReferences = last.scope ?? []
        send(last.question)
    }

    public func sourceIsAvailable(_ source: AssistantSource) async -> Bool {
        guard let meeting = try? await engine.library.meeting(source.meeting) else { return false }
        if let task = source.task, task.resolve(in: meeting) == nil { return false }
        if let utterance = source.utterance, meeting.utterance(utterance) == nil { return false }
        return true
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
            guard let step = turns[index].steps.lastIndex(where: { $0.kind == .plan && $0.state == .running }) else { return }
            turns[index].steps[step].reasoning = reasoning
            turns[index].steps[step].duration = duration
            turns[index].steps[step].state = .done
        case .toolStarted(let id, let kind, let arguments):
            let stepKind: AssistantStep.Kind = switch kind { case .search: .search; case .read: .read; case .tasks: .tasks; case .filing: .filing }
            turns[index].steps.append(.init(id: id, kind: stepKind, arguments: arguments))
        case .toolFinished(let id, let result):
            guard let step = turns[index].steps.firstIndex(where: { $0.id == id }) else { return }
            turns[index].steps[step].result = result
            turns[index].steps[step].state = .done
            for source in result.sources {
                if let existing = turns[index].sources.firstIndex(where: { $0.id == source.id }) { turns[index].sources[existing] = source }
                else { turns[index].sources.append(source) }
            }
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
        case .filed(let batch, let proposals): turns[index].folderBatch = batch; turns[index].folderProposals = proposals; save()
        case .ledger(let value): ledger = value
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
        if turns[index].state != .running || Date().timeIntervalSince(lastCheckpoint) >= 1 { save() }
    }

    private func finish(at index: Int) {
        flushTask?.cancel(); flushTask = nil
        let wasEmpty = turns[index].answer.text.isEmpty
        turns[index].answer.flush(at: Date(), force: true)
        if wasEmpty && !turns[index].answer.text.isEmpty { turns[index].activityExpanded = false }
    }
}
