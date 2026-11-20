import Foundation
import MM2TCore
import MM2TProviders
import Observation
import OSLog

@MainActor @Observable
public final class CollabSession {
    public enum State: Equatable {
        case idle, confirmingStart, needsSignIn, starting, live(CollabRoom), ended
    }

    public enum CommandStatus: Equatable {
        case hidden, input, building(String?), completed(String?), failed(Failure)
    }

    public enum Failure: Equatable {
        case service(CollabError), modelNotConfigured, generation
    }

    private struct Command {
        let text: String
        let source: CollabSource
        let retryTarget: String?
    }

    private struct UpdateMark {
        let time: Date
        let captionCount: Int
    }

    private struct SuggestionResponse: Decodable {
        let suggestion: CollabSuggestion?
        private enum Key: String, CodingKey { case suggest }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            suggestion = try c.decode(Bool.self, forKey: .suggest) ? CollabSuggestion(from: decoder) : nil
        }
    }

    private enum GenerationError: Error { case modelNotConfigured, invalidOutput }
    private static let logger = Logger(subsystem: "dev.mm2t.app", category: "Collaboration")

    public private(set) var state: State = .idle
    public private(set) var commandStatus: CommandStatus = .hidden
    public private(set) var suggestion: CollabSuggestion?
    public private(set) var card: SuggestionPolicy.Card?
    public var wantsKeyboard: Bool { commandStatus == .input || state == .confirmingStart }
    public var room: CollabRoom? { if case .live(let room) = state { room } else { heldRoom } }
    private var heldRoom: CollabRoom?

    @ObservationIgnored private let account: CollabAccount
    @ObservationIgnored private let title: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let makeLLM: () throws -> LLMBuild
    @ObservationIgnored private var policy: SuggestionPolicy
    @ObservationIgnored private var transcript: [LiveCaptions.Segment] = []
    @ObservationIgnored private var totalCharacters = 0
    @ObservationIgnored private var marks: [String: UpdateMark] = [:]
    @ObservationIgnored private var failedUpdates: [String: Date] = [:]
    @ObservationIgnored private var knownComponents: [CollabComponent] = []
    @ObservationIgnored private var pendingCommand: Command?
    @ObservationIgnored private var retryCommand: Command?
    @ObservationIgnored private var needsCaptions = false
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var isBackgroundWork = false
    @ObservationIgnored private var creation: Task<CollabRoom, any Error>?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var completion: Task<Void, Never>?

    init(account: CollabAccount, title: String, now: @escaping () -> Date, makeLLM: @escaping () throws -> LLMBuild) {
        self.account = account
        self.title = title
        self.now = now
        self.makeLLM = makeLLM
        self.policy = SuggestionPolicy(now: now())
    }

    public func toggleCommand() {
        if commandStatus == .input { dismissCommand(); return }
        guard state != .ended, state != .starting, state != .confirmingStart, pendingCommand == nil else { return }
        if case .building = commandStatus { return }
        completion?.cancel()
        commandStatus = .input
    }

    public func dismissCommand() {
        switch commandStatus {
        case .building: return
        default: break
        }
        if state == .starting { return }
        if state == .confirmingStart || state == .needsSignIn {
            state = heldRoom.map(State.live) ?? .idle
            heldRoom = nil
        }
        pendingCommand = nil
        retryCommand = nil
        commandStatus = .hidden
    }

    public func run(command: String) { submit(command, source: .command) }

    public func accept(suggestion: CollabSuggestion) {
        guard self.suggestion == suggestion, pendingCommand == nil else { return }
        clearSuggestion()
        submit(suggestion.instruction, source: .suggestion)
    }

    public func dismissSuggestion() {
        guard suggestion != nil else { return }
        policy.closed(at: now())
        clearSuggestion()
    }

    public func hoverSuggestion(_ hovering: Bool) {
        guard card != nil else { return }
        card?.hover(hovering, now: now())
        if hovering { expiry?.cancel() } else { scheduleExpiry() }
    }

    public func retry() {
        guard let retryCommand else { return }
        submit(retryCommand.text, source: retryCommand.source, retryTarget: retryCommand.retryTarget)
    }

    func accountChanged() {
        guard state == .needsSignIn, account.user != nil, pendingCommand != nil else { return }
        if let heldRoom {
            self.heldRoom = nil
            state = .live(heldRoom)
            commandStatus = .building(nil)
            pump()
        } else {
            state = .confirmingStart
        }
    }

    public func startSharing() {
        guard state == .confirmingStart, pendingCommand != nil else { return }
        guard account.user != nil else { state = .needsSignIn; return }
        state = .starting
        commandStatus = .building(nil)
        let creation = Task { [service = account.service, title] in try await service.createRoom(title: title) }
        self.creation = creation
        Task { [weak self] in
            let result = await creation.result
            guard let self, state == .starting else { return }
            self.creation = nil
            switch result {
            case .success(let room):
                guard account.configuration.accepts(room.shareUrl), account.configuration.accepts(room.hostUrl) else {
                    Task { try? await account.service.endRoom(room.roomId) }
                    fail(CollabError.server(status: 200))
                    state = .idle
                    return
                }
                state = .live(room)
                pump()
            case .failure(let error):
                if error as? CollabError == .notSignedIn {
                    state = .needsSignIn
                    commandStatus = .hidden
                } else {
                    state = .idle
                    fail(error)
                }
            }
        }
    }

    func finalized(_ segment: LiveCaptions.Segment, captionsOn: Bool) {
        guard state != .ended, captionsOn else { return }
        transcript.append(segment)
        totalCharacters += segment.text.count
        policy.record(segment.text.count)
        needsCaptions = true
        pump()
    }

    func end() -> Task<Void, Never>? {
        guard state != .ended else { return nil }
        let room = room
        let creation = creation
        let service = account.service
        state = .ended
        heldRoom = nil
        work?.cancel()
        work = nil
        completion?.cancel()
        clearSuggestion()
        pendingCommand = nil
        retryCommand = nil
        transcript.removeAll()
        commandStatus = .hidden
        if room != nil || creation != nil {
            return Task {
                var ending = room
                if ending == nil, let creation { ending = try? await creation.value }
                if let ending {
                    do { try await service.endRoom(ending.roomId) }
                    catch { Self.logger.error("Could not end the collaboration room") }
                }
            }
        }
        return nil
    }

    private func submit(_ text: String, source: CollabSource, retryTarget: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, state != .ended, pendingCommand == nil else { return }
        if case .building = commandStatus { return }
        completion?.cancel()
        clearSuggestion()
        pendingCommand = Command(text: text, source: source, retryTarget: retryTarget)
        retryCommand = pendingCommand
        if isBackgroundWork { work?.cancel() }
        if let room, account.user != nil {
            state = .live(room)
            heldRoom = nil
            commandStatus = .building(nil)
            pump()
        } else {
            heldRoom = room
            commandStatus = .hidden
            state = account.user == nil ? .needsSignIn : .confirmingStart
        }
    }

    private func pump() {
        guard work == nil, state != .ended else { return }
        if let command = pendingCommand, case .live(let room) = state {
            pendingCommand = nil
            launch { session in
                do { try await session.execute(command, room: room) }
                catch where !Task.isCancelled { session.fail(error) }
                catch {}
            }
        } else if pendingCommand == nil, needsCaptions, commandStatus != .input {
            needsCaptions = false
            let suggest = commandStatus == .hidden && policy.canAsk(now: now(), captionsOn: true, cardVisible: suggestion != nil)
            let update = account.user != nil && room != nil && nextUpdate() != nil
            guard suggest || update else { return }
            launch(background: true) { session in
                if update, let room = session.room { await session.update(room: room) }
                if suggest, !Task.isCancelled, session.pendingCommand == nil, session.commandStatus == .hidden {
                    await session.askForSuggestion()
                }
            }
        }
    }

    private func launch(background: Bool = false, _ action: @escaping @MainActor (CollabSession) async -> Void) {
        isBackgroundWork = background
        work = Task { [weak self] in
            guard let self else { return }
            await action(self)
            work = nil
            isBackgroundWork = false
            pump()
        }
    }

    private func fail(_ error: any Error) {
        pendingCommand = nil
        let failure: Failure
        if let error = error as? CollabError { failure = .service(error) }
        else if case GenerationError.modelNotConfigured = error { failure = .modelNotConfigured }
        else { failure = .generation }
        commandStatus = .failed(failure)
    }

    private func clearSuggestion() {
        expiry?.cancel()
        expiry = nil
        suggestion = nil
        card = nil
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard let card else { return }
        let remaining = card.timeLeft(at: now())
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            if !Task.isCancelled { self?.dismissSuggestion() }
        }
    }

    private func provider() async throws -> any LLMProvider {
        guard case .ready(let provider) = try makeLLM() else { throw GenerationError.modelNotConfigured }
        return await provider.forGeneration()
    }

    private func roomComponents(_ room: CollabRoom) async throws -> [CollabComponent] {
        let response = try await account.service.components(in: room.roomId)
        try Task.checkCancellation()
        guard response.status == .live else { throw CollabError.roomEnded }
        knownComponents = response.components
        return response.components
    }

    private func recent(_ seconds: TimeInterval, at time: Date) -> String {
        transcript.lazy.filter { time.timeIntervalSince($0.ended) <= seconds }.map(\.text).joined(separator: "\n")
    }

    private func askForSuggestion() async {
        guard policy.shouldAsk(now: now(), captionsOn: true, cardVisible: suggestion != nil) else { return }
        do {
            let components = if let room { try await roomComponents(room) } else { [] as [CollabComponent] }
            let titles = components.map(\.title)
            let input = try CollabPrompts.input([
                "captions": .string(recent(180, at: now())), "existingTitles": .array(titles.map(CollabJSON.string)),
                "previousTitles": .array(policy.titles.sorted().map(CollabJSON.string)),
            ])
            let provider = try await provider()
            try Task.checkCancellation()
            var answer = ""
            for try await fragment in provider.streamText(system: CollabPrompts.suggestion, input: input) {
                try Task.checkCancellation()
                answer += fragment
            }
            guard !Task.isCancelled, pendingCommand == nil, commandStatus == .hidden, suggestion == nil,
                  let offer = try JSONDecoder().decode(SuggestionResponse.self, from: Data(answer.utf8)).suggestion,
                  offer.kind != .experimental, policy.offer(title: offer.title, existing: titles) else { return }
            suggestion = offer
            card = SuggestionPolicy.Card(now: now())
            scheduleExpiry()
        } catch where !Task.isCancelled {
            Self.logger.debug("Could not generate a collaboration suggestion")
        } catch {}
    }

    private func execute(_ command: Command, room: CollabRoom) async throws {
        let components = try await roomComponents(room)
        let newID = UUID().uuidString.lowercased()
        let retrying = components.first { $0.id == command.retryTarget }
        let time = now()
        let input = try CollabPrompts.input([
            "instruction": .string(command.text), "captions": .string(recent(300, at: time)),
            "components": .array(components.map { .object(Self.promptFields($0)) }),
            "date": .string(time.formatted(Date.ISO8601FormatStyle(timeZone: .current).timeZone(separator: .colon))), "timeZone": .string(TimeZone.current.identifier),
        ])
        let snapshot = totalCharacters
        let result = try await stream(room: room, system: CollabPrompts.command(source: command.source, newID: newID, retryTarget: retrying?.id), input: input,
                                      route: .init(components: components, newID: newID, source: command.source, retrying: retrying), showTitle: true)
        if let id = result.target { marks[id] = UpdateMark(time: now(), captionCount: snapshot) }
        do { _ = try await roomComponents(room) }
        catch where !Task.isCancelled { Self.logger.debug("Could not refresh the collaboration components") }
        try Task.checkCancellation()
        commandStatus = .completed(result.title)
        completion = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { self?.commandStatus = .hidden }
        }
    }

    private static func promptFields(_ component: CollabComponent) -> [String: CollabJSON] {
        component.fields.filter { !["votes", "elements", "createdAt", "updatedAt", "rev", "building"].contains($0.key) }
    }

    private func updateMark(_ component: CollabComponent) -> UpdateMark {
        if let mark = marks[component.id] { return mark }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let time = format.date(from: component.updatedAt) ?? ISO8601DateFormatter().date(from: component.updatedAt) ?? now()
        return UpdateMark(time: time, captionCount: transcript.lazy.filter { $0.ended <= time }.reduce(0) { $0 + $1.text.count })
    }

    private func nextUpdate() -> String? {
        self.nextUpdate(from: knownComponents)
    }

    private func nextUpdate(from components: [CollabComponent]) -> String? {
        let time = now()
        return LiveUpdatePolicy.next(components.filter {
            !$0.building && (failedUpdates[$0.id].map { time.timeIntervalSince($0) >= 90 } ?? true)
        }.map {
            let mark = updateMark($0)
            return .init(id: $0.id, kind: $0.kind, lastUpdated: mark.time, newCharacters: totalCharacters - mark.captionCount)
        }, now: time, inFlight: false)
    }

    private func update(room: CollabRoom) async {
        var attempted: Set<String> = []
        while !Task.isCancelled, pendingCommand == nil {
            var updating: String?
            do {
                let components = try await roomComponents(room)
                guard let id = nextUpdate(from: components.filter { !attempted.contains($0.id) }),
                      let component = components.first(where: { $0.id == id }) else { return }
                attempted.insert(id)
                updating = id
                let mark = updateMark(component)
                let snapshot = totalCharacters
                var seen = 0
                let text = transcript.filter { segment in
                    seen += segment.text.count
                    return seen > mark.captionCount
                }.map(\.text).joined(separator: "\n")
                let input = try CollabPrompts.input(["component": .object(Self.promptFields(component)), "captions": .string(text)])
                _ = try await stream(room: room, system: CollabPrompts.update, input: input, route: .init(updating: component))
                marks[id] = UpdateMark(time: now(), captionCount: snapshot)
            } catch where !Task.isCancelled {
                if let updating { failedUpdates[updating] = now() }
                Self.logger.debug("Could not update a collaboration component")
                return
            } catch { return }
        }
    }

    private func stream(room: CollabRoom, system: String, input: String, route: CollabGeneration,
                        showTitle: Bool = false) async throws -> CollabGeneration {
        let provider = try await provider()
        try Task.checkCancellation()
        let sender = CollabOpSender { [service = account.service] ops in try await service.sendOps(ops, to: room.roomId) }
        var route = route
        var parser = CollabOpStreamParser()
        defer {
            let discarded = parser.rejectedLines + route.rejected
            if discarded > 0 { Self.logger.notice("Discarded collaboration op lines: \(discarded, privacy: .public)") }
        }
        do {
            try await withTaskCancellationHandler {
                for try await fragment in provider.streamText(system: system, input: input) {
                    for op in parser.feed(fragment) {
                        try Task.checkCancellation()
                        if let approved = route.accept(op) { try await sender.append(approved) }
                        if showTitle { commandStatus = .building(route.title) }
                    }
                }
                try Task.checkCancellation()
                for op in parser.finish() {
                    if let approved = route.accept(op) { try await sender.append(approved) }
                    if showTitle { commandStatus = .building(route.title) }
                }
                guard route.finished else { throw GenerationError.invalidOutput }
                try await sender.finish()
            } onCancel: {
                Task { await sender.cancel() }
            }
        } catch {
            await sender.cancel()
            if !Task.isCancelled, showTitle, let command = retryCommand, let target = route.target {
                retryCommand = Command(text: command.text, source: command.source, retryTarget: target)
                if route.created, let components = try? await roomComponents(room),
                   components.contains(where: { $0.id == target && $0.building }) {
                    try? await account.service.sendOps([.done(id: target)], to: room.roomId)
                }
            }
            throw error
        }
        return route
    }
}
