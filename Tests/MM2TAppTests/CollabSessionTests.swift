import Foundation
import MM2TCore
import MM2TProviders
import Testing
@testable import MM2TApp

@Suite(.serialized) @MainActor struct CollabSessionTests {
    @Test func eachSignInUsesASeparateVerifierAndCancelledLoginDoesNotExchange() async throws {
        let f = try await Fixture()
        let account = f.newAccount()
        var challenges: [String] = []
        for code in [nil, "invalid", "fixture"] {
            await account.signIn(.google) { start in
                let query = try #require(URLComponents(url: start, resolvingAgainstBaseURL: false)?.queryItems)
                let challenge = try #require(query.first { $0.name == "code_challenge" }?.value)
                challenges.append(challenge)
                guard let code else { throw CancellationError() }
                return URL(string: "mm2t://auth?code=\(code)")!
            }
        }
        let exchanges = Array(CollabBackend.exchanges.get.dropFirst())
        #expect(exchanges.compactMap { $0["code"] } == ["invalid", "fixture"])
        let verifiers = exchanges.compactMap { $0["codeVerifier"] }
        #expect(verifiers.allSatisfy { $0.wholeMatch(of: /[A-Za-z0-9_-]{43}/) != nil })
        #expect(verifiers.map(CollabPKCE.challenge) == Array(challenges.dropFirst()))
        #expect(Set(challenges).count == 3)
        #expect(account.user?.id == "test")
        #expect(account.error == nil)
        await account.waitForPendingEnds()
    }

    @Test func confirmedSuggestionUsesOneRoomAndLaterCaptionsUpdateIt() async throws {
        let fixture = try await Fixture()
        let (session, captions, clock, llm) = (fixture.session, fixture.captions, fixture.clock, fixture.llm)
        llm.answerChunks.set([#"{"suggest":true,"kind":"document","title":"會議決議","instruction":"整理目前決議"}"#])
        clock.update { $0.addTimeInterval(20) }
        captions.receive(.partial(String(repeating: "字", count: 40)))
        await session.waitForWork()
        #expect(llm.answerInputs.get.isEmpty)
        captions.receive(.final(String(repeating: "字", count: 40)))
        try #require(await eventually { session.suggestion != nil })
        session.accept(suggestion: try #require(session.suggestion))
        #expect(session.state == .confirmingStart)
        #expect(!CollabBackend.requests.get.contains("/v1/rooms"))

        llm.answerChunks.set([
            #"{"op":"create","id":"model-id","kind":"document","title":"會議決議","source":"command"}"# + "\n",
            #"{"op":"appendText","id":"model-id","field":"markdown","text":"原有決議"}"# + "\n",
            #"{"op":"done","id":"model-id"}"#,
        ])
        session.startSharing()
        try #require(await eventually { session.commandStatus == .completed("會議決議") })
        let document = try #require(CollabBackend.document.get)
        #expect(document.id != "model-id")
        #expect(document.source == .suggestion)
        #expect(document.content == "原有決議")
        #expect(fixture.providerRanOnMain.get == false)
        #expect(session.room?.roomId == "room")

        llm.answerChunks.set([
            "{\"op\":\"replaceText\",\"id\":\"\(document.id)\",\"field\":\"markdown\",\"text\":\"更新後決議\"}\n",
            "{\"op\":\"done\",\"id\":\"\(document.id)\"}",
        ])
        clock.update { $0.addTimeInterval(90) }
        captions.receive(.final(String(repeating: "新", count: 199)))
        await session.waitForWork()
        #expect(CollabBackend.document.get?.content == "原有決議")
        captions.receive(.final("字"))
        try #require(await eventually { CollabBackend.document.get?.content == "更新後決議" })
        #expect(CollabBackend.requests.get.filter { $0 == "/v1/rooms" }.count == 1)
        await session.end()?.value
        #expect(session.state == .ended)
        #expect(CollabBackend.requests.get.last == "/v1/rooms/room/end")
    }

    @Test func endWaitsForInFlightOpsAndDiscardsQueuedWrites() async throws {
        let f = try await Fixture()
        let (received, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        CollabBackend.holdOps.set(signal)
        defer {
            CollabBackend.releaseOps()
            CollabBackend.holdOps.set(nil)
            signal.finish()
        }
        f.llm.answerChunks.set(Fixture.create + Array(repeating:
            #"{"op":"appendText","id":"model-id","field":"markdown","text":"字"}"# + "\n", count: 45)
            + [#"{"op":"done","id":"model-id"}"#])
        f.begin()
        var arrived = received.makeAsyncIterator()
        await arrived.next()
        let sender = try #require(f.session.sender)
        let ending = f.session.end()
        #expect(f.session.room == nil)
        #expect(f.session.state == .ended)
        for _ in 0..<1_000 {
            if await sender.isSealed { break }
            await Task.yield()
        }
        #expect(await sender.isSealed)
        #expect(CollabBackend.events.get == ["ops-start"])
        CollabBackend.holdOps.set(nil)
        CollabBackend.releaseOps()
        await ending?.value
        await f.session.waitForWork()
        f.session.run(command: "不能再送出")
        await f.session.waitForWork()
        #expect(CollabBackend.events.get == ["ops-start", "ops-complete", "end"])
    }

    @Test func opsConflictEndsSessionWithoutOfferingRetry() async throws {
        let f = try await Fixture()
        CollabBackend.roomEnded.set(true)
        f.llm.answerChunks.set(Fixture.create + [Fixture.done])
        f.begin()
        try #require(await eventually { f.session.state == .ended })
        await f.session.waitForWork()
        await f.session.waitForRoomClosure()
        #expect(f.session.commandStatus == .hidden)
        #expect(f.session.room == nil)
        #expect(CollabBackend.events.get == ["ops-start", "end"])
        #expect(try JSONDecoder().decode(Set<CollabPendingEnds.Room>.self, from: Data(contentsOf: f.pendingFile)).isEmpty)
    }

    @Test func offlineEndPersistsAndReplaysOnStartupAndSignIn() async throws {
        let retry = Gate<Bool>()
        let f = try await Fixture(waitOnRetry: { _ = await retry.wait() })
        defer { Task { await retry.open(true) } }
        try await f.makeRoom()
        CollabBackend.offlineEnd.set(true)
        let ending = f.session.end()
        try #require(await eventually { f.retryDelays.get.count == 1 })
        let persistedBeforeRetry = try JSONDecoder().decode(Set<CollabPendingEnds.Room>.self, from: Data(contentsOf: f.pendingFile))
        #expect(persistedBeforeRetry.map(\.id) == ["room"])
        await retry.open(true)
        await ending?.value
        #expect(f.retryDelays.get == [.seconds(2), .seconds(10), .seconds(30)])
        #expect(CollabBackend.events.get.filter { $0 == "end" }.count == 4)
        let persisted = try JSONDecoder().decode(Set<CollabPendingEnds.Room>.self, from: Data(contentsOf: f.pendingFile))
        #expect(persisted.map(\.id) == ["room"])

        let restored = f.newAccount()
        restored.observeSignIn()
        try #require(await eventually { CollabBackend.events.get.filter { $0 == "end" }.count == 8 })
        await restored.waitForPendingEnds()
        #expect(!restored.busy)
        CollabBackend.offlineEnd.set(false)
        try await restored.completeSignIn(code: "fixture", verifier: Fixture.verifier)
        await restored.waitForPendingEnds()
        #expect(CollabBackend.events.get.filter { $0 == "end" }.count == 9)
        #expect(try JSONDecoder().decode(Set<CollabPendingEnds.Room>.self, from: Data(contentsOf: f.pendingFile)).isEmpty)
    }

    @Test func refreshFailureHidesRoomAndOnlyOriginalAccountCanResumeOrEndIt() async throws {
        let f = try await Fixture()
        try await f.makeRoom()
        CollabBackend.expired.set(true)
        await #expect(throws: CollabError.notSignedIn) { try await f.account.service.me() }
        try #require(await eventually { f.session.room == nil && f.account.user == nil })
        #expect(f.session.state == .idle)
        f.session.run(command: "原房間")
        #expect(f.session.state == .needsSignIn)
        f.llm.answerChunks.set([#"{"op":"done","id":"unrelated"}"#])
        try await f.account.completeSignIn(code: "fixture", verifier: Fixture.verifier)
        #expect(f.session.room?.roomId == "room")
        await f.session.waitForWork()

        CollabBackend.expired.set(true)
        await #expect(throws: CollabError.notSignedIn) { try await f.account.service.me() }
        try #require(await eventually { f.session.room == nil && f.account.user == nil })
        f.session.run(command: "新房間")
        try await f.account.completeSignIn(code: "other", verifier: Fixture.verifier)
        #expect(f.session.state == .confirmingStart)
        #expect(f.session.room == nil)
        await f.session.waitForRoomClosure()
        #expect(!CollabBackend.events.get.contains("end"))
        let queued = try JSONDecoder().decode(Set<CollabPendingEnds.Room>.self, from: Data(contentsOf: f.pendingFile))
        #expect(queued.map(\.owner) == ["test"])
        try await f.account.completeSignIn(code: "fixture", verifier: Fixture.verifier)
        await f.account.waitForPendingEnds()
        #expect(CollabBackend.endBearers.get == ["Bearer test-access"])
        #expect(f.session.room == nil)
        await f.session.end()?.value
    }

    @Test func signOutEndsRoomBeforeLogoutAndAllowsAnotherCommandInSameMeeting() async throws {
        let f = try await Fixture()
        try await f.makeRoom()
        await f.account.signOut()
        #expect(CollabBackend.requests.get.suffix(2) == ["/v1/rooms/room/end", "/v1/auth/logout"])
        #expect(f.session.room == nil)
        #expect(f.session.state == .idle)
        f.session.toggleCommand()
        #expect(f.session.commandStatus == .input)
        f.session.run(command: "再次共享")
        #expect(f.session.state == .needsSignIn)
        try await f.account.completeSignIn(code: "fixture", verifier: Fixture.verifier)
        #expect(f.session.state == .confirmingStart)
    }

    @Test func doneOnlyUpdateAdvancesLocalTimeAndCaptionCursorWithoutSendingOps() async throws {
        let f = try await Fixture()
        try await f.makeRoom()
        let doc = try #require(CollabBackend.document.get)
        let oldOps = CollabBackend.events.get
        let oldInputs = f.llm.answerInputs.get.count
        f.llm.answerChunks.set(["{\"op\":\"done\",\"id\":\"\(doc.id)\"}"])
        f.clock.update { $0.addTimeInterval(90) }
        f.captions.receive(.final(String(repeating: "甲", count: 200)))
        await f.session.waitForWork()
        #expect(f.llm.answerInputs.get.count == oldInputs + 1)
        #expect(CollabBackend.events.get == oldOps)
        f.clock.update { $0.addTimeInterval(89) }
        f.captions.receive(.final(String(repeating: "乙", count: 200)))
        await f.session.waitForWork()
        #expect(f.llm.answerInputs.get.count == oldInputs + 1)
        f.clock.update { $0.addTimeInterval(1) }
        f.captions.receive(.final("丙"))
        await f.session.waitForWork()
        #expect(f.llm.answerInputs.get.count == oldInputs + 2)
        #expect(f.llm.answerInputs.get.last?.contains("甲") == false)
        #expect(f.llm.answerInputs.get.last?.contains("乙") == true)
        #expect(CollabBackend.events.get == oldOps)
        await f.session.end()?.value
    }

    @Test func disabledCaptionsSuppressInFlightSuggestion() async throws {
        let f = try await Fixture()
        let gate = Gate<Bool>()
        f.llm.holds.set(["answer": gate])
        f.llm.answerChunks.set([#"{"suggest":true,"kind":"document","title":"會議決議","instruction":"整理決議"}"#])
        f.clock.update { $0.addTimeInterval(20) }
        f.captions.receive(.final(String(repeating: "字", count: 40)))
        try #require(await eventually { f.llm.answerInputs.get.count == 1 })
        f.captions.set(.off)
        await gate.open(true)
        await f.session.waitForWork()
        #expect(f.session.suggestion == nil)
        await f.session.end()?.value
    }

    @Test func turningCaptionsOffWhileUpdateRunsPreventsQueuedSuggestionRequest() async throws {
        let f = try await Fixture()
        try await f.makeRoom()
        let doc = try #require(CollabBackend.document.get)
        f.session.dismissCommand()
        let gate = Gate<Bool>()
        f.llm.holds.set(["answer": gate])
        f.llm.answerChunks.set(["{\"op\":\"done\",\"id\":\"\(doc.id)\"}"])
        let inputs = f.llm.answerInputs.get.count
        f.clock.update { $0.addTimeInterval(90) }
        f.captions.receive(.final(String(repeating: "字", count: 200)))
        defer { Task { await gate.open(true) } }
        try #require(await eventually { f.llm.answerInputs.get.count == inputs + 1 })
        f.captions.set(.off)
        await gate.open(true)
        await f.session.waitForWork()
        #expect(f.llm.answerInputs.get.count == inputs + 1)
        #expect(f.session.suggestion == nil)
        await f.session.end()?.value
    }

    @Test func failedNewCommandRemovesPartialComponentAndRetryCreatesAnother() async throws {
        let f = try await Fixture()
        let modelGate = Gate<Bool>()
        f.llm.holds.set(["answer": modelGate])
        f.llm.failsStream.set(true)
        f.llm.answerChunks.set(Fixture.create)
        f.begin()
        defer { Task { await modelGate.open(true) } }
        try #require(await eventually { CollabBackend.document.get != nil })
        let previous = try #require(CollabBackend.document.get?.id)
        await modelGate.open(true)
        await f.session.waitForWork()
        #expect(CollabBackend.document.get == nil)
        #expect(CollabBackend.ops.get.last == .remove(id: previous))
        #expect(f.session.commandStatus == .failed(.generation))
        f.llm.failsStream.set(false)
        f.llm.answerChunks.set(Fixture.create + [Fixture.done])
        f.session.retry()
        await f.session.waitForWork()
        let replacement = try #require(CollabBackend.document.get)
        #expect(replacement.id != previous)
        #expect(!replacement.building)
        await f.session.end()?.value
    }

    @Test func failedExistingCommandSendsDoneAndCleanupFailureIsVisible() async throws {
        let f = try await Fixture()
        try await f.makeRoom()
        let previous = try #require(CollabBackend.document.get?.id)
        let modelGate = Gate<Bool>()
        f.llm.holds.set(["answer": modelGate])
        f.llm.failsStream.set(true)
        f.llm.answerChunks.set(["{\"op\":\"appendText\",\"id\":\"\(previous)\",\"field\":\"markdown\",\"text\":\"變更\"}\n"])
        f.session.run(command: "修改既有文件")
        defer { Task { await modelGate.open(true) } }
        try #require(await eventually { CollabBackend.document.get?.content == "變更" })
        await modelGate.open(true)
        await f.session.waitForWork()
        #expect(CollabBackend.ops.get.last == .done(id: previous))
        #expect(CollabBackend.document.get?.id == previous)
        #expect(f.session.commandStatus == .failed(.generation))

        CollabBackend.rejectDone.set(true)
        f.session.retry()
        await f.session.waitForWork()
        #expect(f.session.commandStatus == .failed(.service(.server(status: 503))))
        await f.session.end()?.value
    }

    @Test func oversizedTextDoesNotStopLaterValidOps() async throws {
        let f = try await Fixture()
        let text = String(repeating: "頁", count: 75_000) + "\n" + String(repeating: "界", count: 40_000)
        let encoder = JSONEncoder()
        func line(_ op: CollabOp) throws -> String { String(decoding: try encoder.encode(op), as: UTF8.self) + "\n" }
        f.llm.answerChunks.set(Fixture.create + [
            try line(.appendText(id: "model-id", field: .markdown, text: text)),
            try line(.replaceText(id: "model-id", field: .markdown, text: text)),
            try line(.appendText(id: "model-id", field: .markdown, text: "結尾")), Fixture.done,
        ])
        f.begin()
        try #require(await eventually { f.session.commandStatus == .completed("會議決議") })
        #expect(CollabBackend.document.get?.content == text + "結尾")
        let appended = CollabBackend.ops.get.compactMap { op -> String? in
            if case .appendText(_, _, let value) = op { return value }
            return nil
        }
        #expect(appended.count == 3)
        #expect(appended.first?.last == "\n")
        #expect(!CollabBackend.ops.get.contains { if case .replaceText = $0 { true } else { false } })
        await f.session.end()?.value
    }

    @Test(arguments: [CollabOp.Collection.nodes, .edges, .options, .tasks, .rows])
    func missingNewItemFieldsAreRejectedButExistingItemsAllowPartialUpdates(_ collection: CollabOp.Collection) throws {
        let kind: CollabComponentKind = switch collection {
        case .nodes, .edges: .whiteboard
        case .options: .poll
        case .tasks: .gantt
        case .rows: .actions
        }
        let required: [String] = switch collection {
        case .nodes, .options: ["label"]
        case .edges: ["from", "to"]
        case .tasks: ["name", "start", "end"]
        case .rows: ["task"]
        }
        var generation = CollabGeneration(components: [], newID: "real", source: .command)
        _ = try generation.accept(.create(id: "model", kind: kind, title: "Test", source: .command))
        let partial: CollabOp = .upsertItem(id: "model", collection: collection, item: ["id": .string("item")])
        #expect(try generation.accept(partial) == nil)
        var complete: [String: CollabJSON] = ["id": .string("item")]
        for field in required { complete[field] = .string("2026-11-20") }
        #expect(try generation.accept(.upsertItem(id: "model", collection: collection, item: complete)) != nil)
        #expect(try generation.accept(partial) == partial.targeting("real"))
        _ = try generation.accept(.removeItem(id: "model", collection: collection, itemId: "item"))
        #expect(try generation.accept(partial) == nil)
        #expect(try generation.accept(.done(id: "model")) == .done(id: "real"))
        #expect(generation.rejected == 2)
    }

    @Test func invalidItemDoesNotSelectWrongTargetAndSnapshotItemsAllowPartialUpdates() throws {
        func component(_ id: String) throws -> CollabComponent {
            let json = """
            {"id":"\(id)","kind":"actions","title":"待辦","source":"command","building":false,
             "updatedAt":"2026-11-20T12:00:00Z","rows":{"existing":{"id":"existing","task":"聯絡"}}}
            """
            return try JSONDecoder().decode(CollabComponent.self, from: Data(json.utf8))
        }
        var route = CollabGeneration(components: try [component("first"), component("second")], newID: "new", source: .command)
        #expect(try route.accept(.upsertItem(id: "first", collection: .rows, item: ["id": .string("missing")])) == nil)
        #expect(route.target == nil)
        let valid: CollabOp = .upsertItem(id: "second", collection: .rows, item: ["id": .string("existing"), "status": .string("done")])
        #expect(try route.accept(valid) == valid)
        #expect(try route.accept(.done(id: "second")) == .done(id: "second"))
    }

    @Test func oldCaptionsAreRetainedOnlyWhileAnUpdateNeedsThem() async throws {
        let f = try await Fixture()
        f.captions.receive(.final("建房前的字幕"))
        try await f.makeRoom()
        let doc = try #require(CollabBackend.document.get)
        f.captions.receive(.final("距今超過五分鐘"))
        f.clock.update { $0.addTimeInterval(301) }
        f.llm.answerChunks.set(["{\"op\":\"done\",\"id\":\"\(doc.id)\"}"])
        f.captions.receive(.final(String(repeating: "新", count: 200)))
        await f.session.waitForWork()
        #expect(f.llm.answerInputs.get.last?.contains("距今超過五分鐘") == true)
        #expect(f.llm.answerInputs.get.last?.contains("建房前的字幕") == false)
        #expect(f.session.retainedCaptionCount == 1)
        await f.session.end()?.value
    }

    @MainActor private struct Fixture {
        static let verifier = String(repeating: "a", count: 43)
        static let create = [#"{"op":"create","id":"model-id","kind":"document","title":"會議決議","source":"command"}"# + "\n"]
        static let done = #"{"op":"done","id":"model-id"}"#
        let session: CollabSession
        let captions: LiveCaptions
        let account: CollabAccount
        let llm = FakeLLM()
        let providerRanOnMain = Box<Bool?>(nil)
        let clock = Box(Date(timeIntervalSince1970: 1_000))
        let pendingFile: URL
        let retryDelays = Box<[Duration]>([])
        let credentials = MemoryCredentials()
        let http: URLSession
        let configuration = CollabConfiguration(apiURL: URL(string: "https://test.collab.invalid")!,
                                                webURL: URL(string: "https://web.collab.invalid")!)

        init(waitOnRetry: @escaping @Sendable () async -> Void = {}) async throws {
            CollabBackend.reset()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [CollabBackend.self]
            http = URLSession(configuration: config)
            pendingFile = try temporaryDirectory().appending(path: "pending.json")
            account = CollabAccount(configuration: configuration, credentials: credentials, pendingEndsFile: pendingFile,
                                    session: http, endRetrySleep: { [retryDelays] delay in
                retryDelays.update { $0.append(delay) }
                await waitOnRetry()
            })
            captions = LiveCaptions(now: { [clock] in clock.get })
            session = CollabSession(account: account, title: "Test", now: { [clock] in clock.get }, llmSnapshot: { [llm, providerRanOnMain] in
                { providerRanOnMain.set(Thread.isMainThread); return .ready(llm) }
            })
            captions.set(.live)
            session.captionsActive = { [weak captions] in captions?.isActive == true }
            captions.onFinalized = { [weak session] in session?.finalized($0) }
            account.onUserChanged = { [weak session] in session?.accountChanged() }
            account.beforeSignOut = { [weak session] in await session?.signOut() }
            try await account.completeSignIn(code: "fixture", verifier: Fixture.verifier)
            account.observeSignIn()
        }

        func newAccount() -> CollabAccount {
            CollabAccount(configuration: configuration, credentials: credentials, pendingEndsFile: pendingFile,
                          session: http, endRetrySleep: { _ in })
        }

        func begin() {
            session.run(command: "建立文件")
            session.startSharing()
        }

        func makeRoom() async throws {
            llm.answerChunks.set(Self.create + [Self.done])
            begin()
            try #require(await eventually { session.commandStatus == .completed("會議決議") })
        }
    }

}

private final class CollabBackend: URLProtocol, @unchecked Sendable {
    struct Document: Encodable, Sendable {
        let id: String
        let kind = "document"
        let title: String
        let source: CollabSource
        let updatedAt = "1970-01-01T00:17:00Z"
        var building = true
        var content = ""
    }

    static let requests = Box<[String]>([])
    static let document = Box<Document?>(nil)
    static let events = Box<[String]>([])
    static let ops = Box<[CollabOp]>([])
    static let offlineEnd = Box(false)
    static let exchanges = Box<[[String: String]]>([])
    static let roomEnded = Box(false)
    static let rejectDone = Box(false)
    static let expired = Box(false)
    static let endBearers = Box<[String]>([])
    static let holdOps = Box<AsyncStream<Void>.Continuation?>(nil)
    static let deferredReply = Box<(@Sendable () -> Void)?>(nil)

    static func reset() {
        exchanges.set([]); requests.set([]); document.set(nil); events.set([]); ops.set([]); endBearers.set([])
        offlineEnd.set(false); roomEnded.set(false); rejectDone.set(false); expired.set(false); holdOps.set(nil); deferredReply.set(nil)
    }

    static func releaseOps() {
        var reply: (@Sendable () -> Void)?
        deferredReply.update { reply = $0; $0 = nil }
        reply?()
    }

    private struct Batch: Decodable { let batchId: UUID; let ops: [CollabOp] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requests.update { $0.append(url.path) }
        let response: (Int, Data)
        let userID = request.value(forHTTPHeaderField: "Authorization") == "Bearer other-access" ? "other" : "test"
        func identity(_ id: String) -> String { "{\"id\":\"\(id)\",\"name\":\"Host\",\"email\":\"host@example.invalid\"}" }
        let user = identity(userID)
        if Self.expired.get, url.path != "/v1/auth/exchange" {
            reply(status: 401, body: Data())
            return
        }
        switch url.path {
        case "/v1/auth/exchange":
            let exchange = (try? JSONDecoder().decode([String: String].self, from: body())) ?? [:]
            Self.exchanges.update { $0.append(exchange) }
            if exchange["code"] == "invalid" {
                reply(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
                return
            }
            let id = exchange["code"] == "other" ? "other" : "test"
            Self.expired.set(false)
            response = (200, Data("{\"accessToken\":\"\(id)-access\",\"refreshToken\":\"\(id)-refresh\",\"user\":\(identity(id))}".utf8))
        case "/v1/me":
            response = (200, Data("{\"user\":\(user),\"quota\":{\"used\":0,\"limit\":10,\"period\":\"2026-11\"}}".utf8))
        case "/v1/rooms":
            response = (201, Data(#"{"roomId":"room","shareUrl":"https://web.collab.invalid/r/share","hostUrl":"https://web.collab.invalid/r/share#host=code"}"#.utf8))
        case "/v1/rooms/room/components":
            let docs = Self.document.get.map { [$0] } ?? []
            let json = (try? JSONEncoder().encode(docs)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            response = (200, Data("{\"status\":\"live\",\"components\":\(json)}".utf8))
        case "/v1/rooms/room/ops":
            Self.events.update { $0.append("ops-start") }
            if Self.roomEnded.get {
                reply(status: 409, body: Data(#"{"error":"room_ended"}"#.utf8))
                return
            }
            guard let batch = try? JSONDecoder().decode(Batch.self, from: body()) else {
                reply(status: 400, body: Data()); return
            }
            Self.ops.update { $0 += batch.ops }
            if Self.rejectDone.get, batch.ops.contains(where: { if case .done = $0 { true } else { false } }) {
                reply(status: 503, body: Data())
                return
            }
            Self.document.update { document in
                for op in batch.ops {
                    if case .create(let id, _, let title, let source) = op {
                        document = Document(id: id, title: title, source: source)
                        continue
                    }
                    guard document?.id == op.id else { continue }
                    switch op {
                    case .appendText(_, _, let text): document?.content += text
                    case .replaceText(_, _, let text): document?.content = text
                    case .done: document?.building = false
                    case .remove: document = nil
                    default: break
                    }
                }
            }
            let finish: @Sendable () -> Void = { [self] in
                Self.events.update { $0.append("ops-complete") }
                reply(status: 200, body: Data("{\"applied\":\(batch.ops.count),\"duplicate\":false}".utf8))
            }
            if let held = Self.holdOps.get {
                Self.deferredReply.set(finish)
                held.yield(())
            } else { finish() }
            return
        case "/v1/rooms/room/end":
            Self.events.update { $0.append("end") }
            Self.endBearers.update { $0.append(request.value(forHTTPHeaderField: "Authorization") ?? "") }
            if Self.offlineEnd.get {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            response = (200, Data(#"{"status":"ended"}"#.utf8))
        case "/v1/auth/logout": response = (200, Data(#"{"ok":true}"#.utf8))
        default: response = (404, Data())
        }
        reply(status: response.0, body: response.1)
    }

    private func reply(status: Int, body: Data) {
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func body() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 2048)
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }
}
