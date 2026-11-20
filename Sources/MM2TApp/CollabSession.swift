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

    private struct Command: Sendable {
        let text: String
        let source: CollabSource
        let retryTarget: String?
    }

    private struct UpdateMark {
        let time: Date
        let captionCount: Int
    }

    private struct OwnedRoom {
        let room: CollabRoom
        let owner: String
    }

    private struct Caption {
        let segment: LiveCaptions.Segment
        let position: Int
    }

    private static let logger = Logger(subsystem: "dev.mm2t.app", category: "Collaboration")

    public private(set) var state: State = .idle
    public private(set) var commandStatus: CommandStatus = .hidden
    public private(set) var suggestion: CollabSuggestion?
    public private(set) var card: SuggestionPolicy.Card?
    public var wantsKeyboard: Bool { commandStatus == .input || state == .confirmingStart }
    public var room: CollabRoom? { if case .live(let room) = state { room } else { nil } }
    public var retainedHostURL: URL? { ownedRoom?.room.hostUrl }
    private var ownedRoom: OwnedRoom?
    @ObservationIgnored private(set) var sender: CollabOpSender?
    @ObservationIgnored private var draining: Task<Void, Never>?
    @ObservationIgnored private var closingRoom: Task<Void, Never>?
    @ObservationIgnored var captionsActive: () -> Bool = { false }

    @ObservationIgnored private let account: CollabAccount
    @ObservationIgnored private let title: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let llmSnapshot: () -> (@Sendable () throws -> LLMBuild)
    @ObservationIgnored private var policy: SuggestionPolicy
    @ObservationIgnored private var transcript: [Caption] = []
    @ObservationIgnored private var totalCharacters = 0
    @ObservationIgnored private var marks: [String: UpdateMark] = [:]
    @ObservationIgnored private var failedUpdates: [String: Date] = [:]
    @ObservationIgnored private var knownComponents: [CollabComponent] = []
    @ObservationIgnored private var pendingCommand: Command?
    @ObservationIgnored private var retryCommand: Command?
    @ObservationIgnored private var needsCaptions = false
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var isBackgroundWork = false
    @ObservationIgnored private var creationOwner: String?
    @ObservationIgnored private var creation: Task<OwnedRoom, any Error>?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var completion: Task<Void, Never>?

    init(account: CollabAccount, title: String, now: @escaping () -> Date, llmSnapshot: @escaping () -> (@Sendable () throws -> LLMBuild)) {
        self.account = account
        self.title = title
        self.now = now
        self.llmSnapshot = llmSnapshot
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
            state = .idle
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
        guard state != .ended else { return }
        guard let user = account.user else {
            if ownedRoom != nil || creation != nil {
                resetSharing()
            } else if state == .confirmingStart {
                state = .needsSignIn
            }
            return
        }
        if let ownedRoom {
            if ownedRoom.owner == user.id {
                state = .live(ownedRoom.room)
                if pendingCommand != nil { commandStatus = .building(nil) }
                pump()
                return
            }
            if state != .needsSignIn { resetSharing() }
            closeSharing()
        } else if let creationOwner, creationOwner != user.id {
            resetSharing()
            closeSharing()
        }
        if state == .needsSignIn, pendingCommand != nil {
            if creation == nil { state = .confirmingStart }
            else { state = .starting; commandStatus = .building(nil) }
        }
    }

    func signOut() async {
        resetSharing()
        closeSharing()
        await closingRoom?.value
    }

    private func resetSharing() {
        if state != .ended { state = .idle }
        work?.cancel()
        completion?.cancel()
        clearSuggestion()
        pendingCommand = nil
        retryCommand = nil
        commandStatus = .hidden
        if draining == nil, let sender {
            draining = Task {
                await sender.close()
                draining = nil
                pump()
            }
        }
    }

    private func closeSharing() {
        let room = ownedRoom
        let creation = creation
        ownedRoom = nil
        self.creation = nil
        creationOwner = nil
        knownComponents.removeAll()
        marks.removeAll()
        failedUpdates.removeAll()
        let previous = closingRoom
        let draining = draining
        guard room != nil || creation != nil else { return }
        closingRoom = Task { [account] in
            await previous?.value
            await draining?.value
            let ending = if let room { room } else { try? await creation?.value }
            if let ending { await account.closeRoom(ending.room, owner: ending.owner) }
        }
    }

    public func startSharing() {
        guard state == .confirmingStart, creation == nil, pendingCommand != nil else { return }
        guard let owner = account.user?.id, !account.signingOut else { state = .needsSignIn; return }
        state = .starting
        commandStatus = .building(nil)
        let creation = Task { [service = account.service, title] in
            OwnedRoom(room: try await service.createRoom(title: title, owner: owner), owner: owner)
        }
        self.creation = creation
        creationOwner = owner
        Task { [weak self] in
            let result = await creation.result
            guard let self, self.creation == creation else { return }
            self.creation = nil
            creationOwner = nil
            switch result {
            case .success(let binding):
                let room = binding.room
                ownedRoom = binding
                guard account.configuration.accepts(room.shareUrl), account.configuration.accepts(room.hostUrl) else {
                    closeSharing()
                    fail(CollabError.server(status: 200))
                    state = .idle
                    return
                }
                guard account.user?.id == binding.owner, !account.signingOut else { return }
                state = .live(room)
                if pendingCommand != nil { commandStatus = .building(nil) }
                pump()
            case .failure(let error):
                guard state == .starting else { return }
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

    func finalized(_ segment: LiveCaptions.Segment) {
        guard state != .ended, captionsActive() else { return }
        totalCharacters += segment.text.count
        transcript.append(Caption(segment: segment, position: totalCharacters))
        policy.record(segment.text.count)
        pruneCaptions()
        needsCaptions = true
        pump()
    }

    private func pruneCaptions() {
        let cutoff = now().addingTimeInterval(-300)
        let oldestPosition = knownComponents.lazy.filter { $0.kind.updatesLive }
            .map { self.updateMark($0).captionCount }.min() ?? totalCharacters
        if let keep = transcript.firstIndex(where: { $0.segment.ended >= cutoff || $0.position > oldestPosition }) {
            transcript.removeFirst(keep)
        } else {
            transcript.removeAll(keepingCapacity: true)
        }
    }

    var retainedCaptionCount: Int { transcript.count }

    func waitForRoomClosure() async { await closingRoom?.value }

    func waitForWork() async {
        while let work { await work.value }
    }

    func end() -> Task<Void, Never>? {
        guard state != .ended else { return closingRoom }
        state = .ended
        resetSharing()
        closeSharing()
        transcript.removeAll()
        return closingRoom
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
        if let room, account.user != nil, !account.signingOut {
            state = .live(room)
            commandStatus = .building(nil)
            pump()
        } else {
            commandStatus = .hidden
            state = account.user == nil || account.signingOut ? .needsSignIn : .confirmingStart
        }
    }

    private func pump() {
        guard work == nil, draining == nil, state != .ended, !account.signingOut else { return }
        if let command = pendingCommand, case .live(let room) = state {
            pendingCommand = nil
            launch { session in
                do { try await session.execute(command, room: room) }
                catch where !Task.isCancelled { session.fail(error) }
                catch {}
            }
        } else if pendingCommand == nil, needsCaptions, commandStatus != .input {
            needsCaptions = false
            let suggest = commandStatus == .hidden && policy.canAsk(now: now(), captionsOn: captionsActive(), cardVisible: suggestion != nil)
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
        else if case CollabModelWork.Failure.modelNotConfigured = error { failure = .modelNotConfigured }
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

    private func roomComponents(_ room: CollabRoom) async throws -> [CollabComponent] {
        guard let binding = ownedRoom, binding.room == room else { throw CollabError.notSignedIn }
        let response = try await account.service.components(in: room.roomId, owner: binding.owner)
        try Task.checkCancellation()
        guard response.status == .live else {
            _ = end()
            throw CollabError.roomEnded
        }
        knownComponents = response.components
        pruneCaptions()
        return response.components
    }

    private func recent(_ seconds: TimeInterval, at time: Date) -> [String] {
        transcript.filter { time.timeIntervalSince($0.segment.ended) <= seconds }.map(\.segment.text)
    }

    private func askForSuggestion() async {
        guard policy.shouldAsk(now: now(), captionsOn: captionsActive(), cardVisible: suggestion != nil) else { return }
        do {
            let components = if let room { try await roomComponents(room) } else { [] as [CollabComponent] }
            guard !Task.isCancelled, captionsActive() else { return }
            let titles = components.map(\.title)
            let captions = recent(180, at: now())
            let previousTitles = policy.titles
            let model = CollabModelWork(makeLLM: llmSnapshot())
            let offer = try await model.suggestion {
                ["captions": .string(captions.joined(separator: "\n")), "existingTitles": .array(titles.map(CollabJSON.string)),
                 "previousTitles": .array(previousTitles.sorted().map(CollabJSON.string))]
            }
            guard !Task.isCancelled, captionsActive(), pendingCommand == nil, commandStatus == .hidden, suggestion == nil,
                  let offer, offer.kind != .experimental, policy.offer(title: offer.title, existing: titles) else { return }
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
        let captions = recent(300, at: time)
        let snapshot = totalCharacters
        let result = try await stream(room: room, system: CollabPrompts.command(source: command.source, newID: newID, retryTarget: retrying?.id),
                                      route: .init(components: components, newID: newID, source: command.source, retrying: retrying), showTitle: true) {
            ["instruction": .string(command.text), "captions": .string(captions.joined(separator: "\n")),
             "components": .array(components.map { .object(CollabModelWork.promptFields($0)) }),
             "date": .string(time.formatted(Date.ISO8601FormatStyle(timeZone: .current).timeZone(separator: .colon))), "timeZone": .string(TimeZone.current.identifier)]
        }
        try Task.checkCancellation()
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

    private func updateMark(_ component: CollabComponent) -> UpdateMark {
        if let mark = marks[component.id] { return mark }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let time = format.date(from: component.updatedAt) ?? ISO8601DateFormatter().date(from: component.updatedAt) ?? now()
        return UpdateMark(time: time, captionCount: transcript.last { $0.segment.ended <= time }?.position ?? transcript.first.map { $0.position - $0.segment.text.count } ?? totalCharacters)
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
                let captions = transcript.lazy.filter { $0.position > mark.captionCount }.map(\.segment.text)
                let texts = Array(captions)
                _ = try await stream(room: room, system: CollabPrompts.update, route: .init(updating: component)) {
                    ["component": .object(CollabModelWork.promptFields(component)), "captions": .string(texts.joined(separator: "\n"))]
                }
                try Task.checkCancellation()
                marks[id] = UpdateMark(time: now(), captionCount: snapshot)
                pruneCaptions()
            } catch where !Task.isCancelled {
                if let updating { failedUpdates[updating] = now() }
                Self.logger.debug("Could not update a collaboration component")
                return
            } catch { return }
        }
    }

    private func stream(room: CollabRoom, system: String, route: CollabGeneration, showTitle: Bool = false,
                        input: @escaping @Sendable () -> [String: CollabJSON]) async throws -> CollabGeneration {
        guard let binding = ownedRoom, binding.room == room else { throw CollabError.notSignedIn }
        try Task.checkCancellation()
        let sender = makeSender(room, owner: binding.owner)
        self.sender = sender
        defer { self.sender = nil }
        let model = CollabModelWork(makeLLM: llmSnapshot(), route: route)
        do {
            return try await model.stream(system: system, input: input, sender: sender) { [weak self] title in
                if showTitle, !Task.isCancelled { self?.commandStatus = .building(title) }
            }
        } catch {
            await sender.close()
            let route = await model.generation
            if !Task.isCancelled, showTitle, let command = retryCommand, let route, let target = route.target {
                if !route.created { retryCommand = Command(text: command.text, source: command.source, retryTarget: target) }
                if route.needsCleanup {
                    do { try await cleanUpCommand(route, target: target, binding: binding) }
                    catch {
                        if !Task.isCancelled {
                            Self.logger.error("Could not clean up a failed collaboration command: \(String(describing: error), privacy: .private)")
                        }
                        throw error
                    }
                }
            }
            throw error
        }
    }

    private func cleanUpCommand(_ route: CollabGeneration, target: String, binding: OwnedRoom) async throws {
        if route.created || route.removed {
            let components = try await roomComponents(binding.room)
            guard components.contains(where: { $0.id == target }) else { return }
        }
        try Task.checkCancellation()
        let cleanup = makeSender(binding.room, owner: binding.owner)
        sender = cleanup
        try await cleanup.append(route.created ? .remove(id: target) : .done(id: target))
        try await cleanup.finish()
    }

    private func makeSender(_ room: CollabRoom, owner: String) -> CollabOpSender {
        CollabOpSender { [weak self, service = account.service] batch in
            do { try await service.sendOps(batch, to: room.roomId, owner: owner) }
            catch CollabError.roomEnded {
                await self?.didDetectEndedRoom(room, owner: owner)
                throw CollabError.roomEnded
            }
        }
    }

    private func didDetectEndedRoom(_ room: CollabRoom, owner: String) {
        guard ownedRoom?.room == room, ownedRoom?.owner == owner else { return }
        _ = end()
    }
}
