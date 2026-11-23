import Foundation
import MM2TCore
import MM2TProviders
import Testing
@testable import MM2TApp

@Suite(.serialized) @MainActor struct CollabSessionTests {
    @Test(arguments: [nil, "", "https://marketing.invalid:8443/en/account/"] as [String?])
    func accountConfigurationLoadsFromPlistOrFallsBack(accountValue: String?) throws {
        let directory = try temporaryDirectory().appending(path: "Account.bundle")
        let contents = directory.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let web = try #require(URL(string: "https://web.collab.invalid"))
        var info = ["MM2TCollabAPIURL": "https://api.collab.invalid", "MM2TCollabWebURL": web.absoluteString]
        info["MM2TAccountWebURL"] = accountValue
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        let bundle = try #require(Bundle(url: directory))
        let config = try #require(CollabConfiguration.live(bundle: bundle, environment: [:]))
        let expected = accountValue.flatMap { $0.isEmpty ? nil : URL(string: $0) } ?? web
        #expect(config.accountURL == expected)
        #expect(config.accepts(web))
        #expect(config.acceptsAccountPage(expected))
        #expect(!config.acceptsAccountPage(try #require(URL(string: "http://\(expected.host!)"))))
        #if DEBUG
        let override = "http://localhost:8081/account/"
        let overridden = try #require(CollabConfiguration.live(bundle: bundle, environment: ["MM2T_ACCOUNT_WEB_URL": override]))
        #expect(overridden.accountURL.absoluteString == override)
        #endif
    }

    @Test func accountRestoresQuotaAndClearsItOnSignOut() async throws {
        let fixture = try await Fixture()
        #expect(fixture.account.quota?.limit == 10)

        CollabBackend.quotaUsed.set(3)
        let restored = fixture.newAccount()
        restored.observeSignIn()
        let didRestore = await waitForCollabEvent { restored.user != nil }
        try #require(didRestore)
        #expect(restored.quota?.used == 3)
        #expect(restored.quota?.limit == 10)
        #expect(restored.quota?.period == "2026-11")

        await restored.signOut()
        #expect(restored.user == nil)
        #expect(restored.quota == nil)
    }

    @Test func onlyKnownFreeAccountsHideTheHostingEntry() async throws {
        let fixture = try await Fixture()
        let session = fixture.session
        #expect(session.showsCommandButton, "unknown plans keep the existing entry")
        session.run(command: "建立文件")
        #expect(session.state == .confirmingStart)

        CollabBackend.planName.set("free")
        CollabBackend.planUsedSeconds.set(0)
        await fixture.account.refreshProfile()
        #expect(!session.allowsRoomCommands)
        #expect(!session.showsCommandButton)
        #expect(!session.wantsKeyboard)
        session.startSharing()
        #expect(!CollabBackend.requests.get.contains("/v1/rooms"))
        session.dismissCommand()
        session.run(command: "建立文件")
        #expect(session.state == .idle)

        for plan in ["standard", "pro"] {
            CollabBackend.planName.set(plan)
            await fixture.account.refreshProfile()
            #expect(session.allowsRoomCommands)
            #expect(session.showsCommandButton)
        }
        await fixture.account.signOut()
        #expect(session.showsCommandButton)
    }

    @Test func roomCreationPlanRequiredShowsThePaidPlanMessage() async throws {
        let fixture = try await Fixture()
        CollabBackend.blockRoomCreation.set(true)
        fixture.begin()
        #expect(await eventually { fixture.session.commandStatus == .failed(.service(.planRequired)) })
        #expect(CollabError.planRequired.collabMessage == "Hosting a room needs a Standard or Pro plan.")
    }

    @Test func planLabelUsesWholeMinutesAndFallsBackToSharedMeetings() async throws {
        let fixture = try await Fixture()
        let account = fixture.account
        #expect(account.planName == nil)
        #expect(account.planAndQuotaLabel == "0 / 10 shared meetings")
        CollabBackend.quotaUsed.set(3)
        for (seconds, label) in [(18720, "Pro · 312 / 900 min"), (59, "Pro · 0 / 900 min"), (-120, "Pro · 0 / 900 min")] {
            CollabBackend.planUsedSeconds.set(seconds)
            await account.refreshProfile()
            #expect(account.planName == "Pro")
            #expect(account.planAndQuotaLabel == label)
        }
        CollabBackend.planUsedSeconds.set(nil)
        await account.refreshProfile()
        #expect(account.planName == nil)
        #expect(account.planAndQuotaLabel == "3 / 10 shared meetings")

        CollabBackend.planUsedSeconds.set(18720)
        await account.refreshProfile()
        try #require(account.plan != nil)
        await account.signOut()
        #expect(account.plan == nil)
        #expect(account.planAndQuotaLabel == nil)
    }

    @Test(arguments: ["account.invalid", "web.collab.invalid", "other.invalid", "account.invalid:443", "user:pass@account.invalid"])
    func openAccountPageOnlyOpensTheConfiguredAccountOrigin(host: String) async throws {
        let fixture = try await Fixture()
        let account = fixture.account
        let url = try #require(URL(string: "https://\(host)/account#handoff=code"))
        CollabBackend.handoffURL.set(url.absoluteString)
        var opened: [URL] = []
        await account.openAccountPage {
            #expect(account.busy)
            opened.append($0)
        }
        #expect(!account.busy)
        if host == "account.invalid" {
            #expect(opened == [url])
            #expect(account.error == nil)
        } else {
            #expect(opened.isEmpty)
            #expect(account.error == .server(status: 0))
        }
    }

    @Test func openAccountPageReportsUnavailableWithoutOpening() async throws {
        let fixture = try await Fixture()
        await fixture.account.openAccountPage { _ in Issue.record("Unexpected URL") }
        #expect(fixture.account.error == .server(status: 503))
        #expect(fixture.account.user != nil)
        #expect(!fixture.account.busy)
    }

    @Test func refreshUpdatesQuotaAndKeepsTheProfileOnServerError() async throws {
        let fixture = try await Fixture()
        let account = fixture.account
        let signedInUser = try #require(account.user)

        CollabBackend.quotaUsed.set(4)
        await account.refreshProfile()
        #expect(account.quota?.used == 4)

        CollabBackend.profileUnavailable.set(true)
        await account.refreshProfile()
        #expect(account.user == signedInUser)
        #expect(account.quota?.used == 4)
        #expect(!account.busy)

        let newAccount = fixture.newAccount()
        try await newAccount.completeSignIn(code: "fixture", verifier: Fixture.verifier)
        #expect(newAccount.user == signedInUser)
        #expect(newAccount.quota == nil)
    }

    @Test func overlappingProfileRefreshesShareTheResponse() async throws {
        let fixture = try await Fixture()
        CollabBackend.requests.set([])
        CollabBackend.quotaUsed.set(4)
        CollabBackend.holdNextProfile.set(true)
        defer { CollabBackend.releaseProfile() }
        let first = Task { await fixture.account.refreshProfile() }
        try #require(await waitForCollabEvent { CollabBackend.deferredProfile.get != nil })

        CollabBackend.quotaUsed.set(7)
        let entered = Box(false)
        let secondReturned = Box(false)
        let second = Task {
            entered.set(true)
            await fixture.account.refreshProfile()
            secondReturned.set(true)
        }
        try #require(await waitForCollabEvent { entered.get })
        #expect(!(await waitForCollabEvent(until: .milliseconds(50)) { secondReturned.get }))
        CollabBackend.releaseProfile()
        await first.value
        await second.value
        #expect(CollabBackend.requests.get.filter { $0 == "/v1/me" }.count == 1)
        #expect(fixture.account.quota?.used == 4)
    }

    @Test func refreshAfterCompletionMakesANewRequest() async throws {
        let fixture = try await Fixture()
        CollabBackend.requests.set([])
        CollabBackend.quotaUsed.set(4)
        await fixture.account.refreshProfile()
        CollabBackend.quotaUsed.set(7)
        await fixture.account.refreshProfile()
        #expect(CollabBackend.requests.get.filter { $0 == "/v1/me" }.count == 2)
        #expect(fixture.account.quota?.used == 7)
    }

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
        CollabBackend.holdOps.set(true)
        defer {
            CollabBackend.holdOps.set(false)
            CollabBackend.releaseOps()
        }
        f.llm.answerChunks.set(Fixture.create + Array(repeating:
            #"{"op":"appendText","id":"model-id","field":"markdown","text":"字"}"# + "\n", count: 45)
            + [Fixture.done])
        f.begin()
        try #require(await waitForCollabEvent { CollabBackend.deferredReply.get != nil })
        let sender = try #require(f.session.sender)
        let ending = f.session.end()
        #expect(f.session.room == nil)
        #expect(f.session.state == .ended)
        #expect(f.account.hasPendingRoomEndWrites)
        await f.account.waitForRoomEndWrites()
        #expect(!f.account.hasPendingRoomEndWrites)
        let recordedBeforeDrain = try JSONDecoder().decode(Set<CollabPendingEnds.Room>.self, from: Data(contentsOf: f.pendingFile))
        #expect(recordedBeforeDrain == [.init(apiURL: f.configuration.apiURL, owner: "test", id: "room")])
        try #require(await waitForCollabEvent { await sender.isSealed })
        #expect(CollabBackend.events.get == ["ops-start"])
        CollabBackend.holdOps.set(false)
        CollabBackend.releaseOps()
        await ending?.value
        await f.session.waitForWork()
        f.session.run(command: "不能再送出")
        await f.session.waitForWork()
        #expect(CollabBackend.events.get == ["ops-start", "ops-complete", "end"])
    }

    @Test func opsConflictEndsSessionWithoutCommandButtonOrRetry() async throws {
        let f = try await Fixture()
        CollabBackend.roomEnded.set(true)
        f.llm.answerChunks.set(Fixture.create + [Fixture.done])
        f.begin()
        try #require(await eventually { f.session.state == .ended })
        await f.session.waitForWork()
        await f.session.waitForRoomClosure()
        #expect(!f.session.showsCommandButton)
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

    @Test func quitWaitsForInFlightCreationAndRecordsRoomBeforeRemoteEnd() async throws {
        let retry = Gate<Bool>()
        let f = try await Fixture(waitOnRetry: { _ = await retry.wait() })
        defer {
            CollabBackend.releaseCreation()
            Task { await retry.open(true) }
        }
        CollabBackend.holdCreation.set(true)
        CollabBackend.offlineEnd.set(true)
        f.begin()
        try #require(await waitForCollabEvent { CollabBackend.deferredCreation.get != nil })
        let closing = try #require(f.account.prepareToQuit(closing: f.session))
        #expect(f.account.hasPendingRoomEndWrites)
        let quitReturned = Box(false)
        let quit = Task {
            await closing.value
            quitReturned.set(true)
        }
        #expect(!(await waitForCollabEvent(until: .milliseconds(50)) { quitReturned.get }))
        #expect(!FileManager.default.fileExists(atPath: f.pendingFile.path))
        CollabBackend.releaseCreation()
        try #require(await waitForCollabEvent { quitReturned.get })
        await quit.value
        #expect(!f.account.hasPendingRoomEndWrites)
        let saved = try JSONDecoder().decode(Set<CollabPendingEnds.Room>.self, from: Data(contentsOf: f.pendingFile))
        #expect(saved == [.init(apiURL: f.configuration.apiURL, owner: "test", id: "room")])
        try #require(await eventually { f.retryDelays.get == [.seconds(2)] })
        await retry.open(true)
        await f.session.waitForRoomClosure()
    }

    @Test func quitRegistersAnActiveRoomWithoutEndingItFirst() async throws {
        let f = try await Fixture()
        try await f.makeRoom()
        CollabBackend.offlineEnd.set(true)
        #expect(!f.account.hasPendingRoomEndWrites)
        let quit = try #require(f.account.prepareToQuit(closing: f.session))
        await quit.value
        #expect(f.session.state == .ended)
        let saved = try JSONDecoder().decode(Set<CollabPendingEnds.Room>.self, from: Data(contentsOf: f.pendingFile))
        #expect(saved == [.init(apiURL: f.configuration.apiURL, owner: "test", id: "room")])
        await f.session.waitForRoomClosure()
    }

    @Test func quitReturnsWhileRegisteredWorkIsStillWaiting() async throws {
        let f = try await Fixture()
        let gate = Gate<Bool>()
        let entered = Box(false)
        let preparation = f.account.prepareRoomEnd {
            entered.set(true)
            _ = await gate.wait()
        }
        defer { Task { await gate.open(true) } }
        try #require(await waitForCollabEvent { entered.get })

        let quitReturned = Box(false)
        let quit = Task {
            await f.account.waitForRoomEndWrites()
            quitReturned.set(true)
        }
        #expect(await waitForCollabEvent(until: .milliseconds(2_500)) { quitReturned.get })
        #expect(f.account.hasPendingRoomEndWrites)
        await gate.open(true)
        await preparation.value
        await quit.value
    }

    @Test func quitAttemptsExactlyThreeLocalWritesOnPermanentFailure() async throws {
        let writes = Box(0)
        let f = try await Fixture(pendingEndsWrite: { _, _ in
            writes.update { $0 += 1 }
            throw CocoaError(.fileWriteNoPermission)
        })
        try await f.makeRoom()
        CollabBackend.offlineEnd.set(true)
        await f.session.end()?.value
        #expect(writes.get == 1)
        writes.set(0)

        await f.account.waitForRoomEndWrites()
        #expect(writes.get == 3)
        #expect(f.account.hasPendingRoomEndWrites)
    }

    @Test(arguments: [false, true])
    func quitRetriesUnpersistedRoomClosureAndReturnsOnPermanentFailure(repairFile: Bool) async throws {
        let f = try await Fixture()
        try await f.makeRoom()
        try FileManager.default.createDirectory(at: f.pendingFile, withIntermediateDirectories: false)
        CollabBackend.offlineEnd.set(true)
        await f.session.end()?.value
        #expect(f.account.error == .pendingEndPersistence)
        #expect(f.account.hasPendingRoomEndWrites)
        if repairFile { try FileManager.default.removeItem(at: f.pendingFile) }

        let clock = ContinuousClock()
        let start = clock.now
        await f.account.waitForRoomEndWrites()
        #expect(start.duration(to: clock.now) <= .seconds(3))
        if repairFile {
            #expect(!f.account.hasPendingRoomEndWrites)
            let saved = try JSONDecoder().decode(Set<CollabPendingEnds.Room>.self, from: Data(contentsOf: f.pendingFile))
            #expect(saved.map(\.id) == ["room"])
        } else {
            #expect(f.account.hasPendingRoomEndWrites)
            #expect(f.account.error == .pendingEndPersistence)
        }
        #expect(CollabBackend.endBearers.get.count == 4)
    }

    @Test func unwritablePendingEndReportsErrorAndReplaysFromMemory() async throws {
        let f = try await Fixture()
        try await f.makeRoom()
        try FileManager.default.createDirectory(at: f.pendingFile, withIntermediateDirectories: false)
        CollabBackend.offlineEnd.set(true)
        let ending = f.session.end()
        await ending?.value
        #expect(f.account.error == .pendingEndPersistence)
        try FileManager.default.removeItem(at: f.pendingFile)
        CollabBackend.offlineEnd.set(false)
        try await f.account.completeSignIn(code: "fixture", verifier: Fixture.verifier)
        await f.account.waitForPendingEnds()
        #expect(CollabBackend.endBearers.get == Array(repeating: "Bearer test-access", count: 5))
    }

    @Test func nextSuccessfulPendingEndWriteAlsoSavesPreviouslyUnwrittenRooms() async throws {
        let f = try await Fixture()
        try FileManager.default.createDirectory(at: f.pendingFile, withIntermediateDirectories: true)
        let pending = CollabPendingEnds(file: f.pendingFile, sleep: { _ in })
        let first = CollabPendingEnds.Room(apiURL: f.configuration.apiURL, owner: "test", id: "first")
        let second = CollabPendingEnds.Room(apiURL: f.configuration.apiURL, owner: "test", id: "second")
        pending.reserve(first)
        await #expect(throws: CollabError.pendingEndPersistence) { try await pending.record(first) }
        try FileManager.default.removeItem(at: f.pendingFile)
        pending.reserve(second)
        try await pending.record(second)
        let saved = try JSONDecoder().decode(Set<CollabPendingEnds.Room>.self, from: Data(contentsOf: f.pendingFile))
        #expect(saved == [first, second])
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

    @Test(arguments: [false, true])
    func interruptedCommandCleanupBelongsToOriginalAccount(switchAccount: Bool) async throws {
        let f = try await Fixture()
        CollabBackend.holdOps.set(true)
        defer {
            CollabBackend.holdOps.set(false)
            CollabBackend.releaseOps()
        }
        f.llm.answerChunks.set(Fixture.create + Array(repeating:
            #"{"op":"appendText","id":"model-id","field":"markdown","text":"字"}"# + "\n", count: 19)
            + [Fixture.done])
        f.begin()
        try #require(await waitForCollabEvent { CollabBackend.deferredReply.get != nil })
        let partial = try #require(CollabBackend.document.get)
        #expect(partial.building)
        CollabBackend.expired.set(true)
        CollabBackend.holdOps.set(false)
        CollabBackend.releaseOps()
        try #require(await eventually { f.account.user == nil && f.session.room == nil })
        await f.session.waitForWork()
        #expect(CollabBackend.requests.get.contains("/v1/auth/refresh"))
        #expect(CollabBackend.document.get?.id == partial.id)
        #expect(CollabBackend.document.get?.building == true)

        if switchAccount {
            try await f.account.completeSignIn(code: "other", verifier: Fixture.verifier)
            await f.session.waitForRoomClosure()
            await f.account.waitForPendingEnds()
            #expect(f.session.room == nil)
            #expect(CollabBackend.document.get?.id == partial.id)
            #expect(!CollabBackend.ops.get.contains(.remove(id: partial.id)))
            #expect(CollabBackend.endBearers.get.isEmpty)
            return
        }

        CollabBackend.holdOps.set(true)
        try await f.account.completeSignIn(code: "fixture", verifier: Fixture.verifier)
        try #require(await waitForCollabEvent { CollabBackend.deferredReply.get != nil })
        #expect(!f.session.showsCommandButton)
        let prompts = f.llm.answerInputs.get.count
        f.session.run(command: "收尾前不可接受新指令")
        #expect(f.llm.answerInputs.get.count == prompts)
        #expect(CollabBackend.ops.get.last == .remove(id: partial.id))
        CollabBackend.holdOps.set(false)
        CollabBackend.releaseOps()
        await f.session.waitForWork()
        #expect(CollabBackend.document.get == nil)
        #expect(f.session.showsCommandButton)
        f.session.toggleCommand()
        #expect(f.session.commandStatus == .input)
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

    @Test(arguments: [false, true])
    func doneOnlyUpdateAdvancesLocalTimeAndCaptionCursorWithoutSendingOps(trailingOutput: Bool) async throws {
        let f = try await Fixture()
        try await f.makeRoom()
        let doc = try #require(CollabBackend.document.get)
        let oldOps = CollabBackend.events.get
        let oldInputs = f.llm.answerInputs.get.count
        let done = "{\"op\":\"done\",\"id\":\"\(doc.id)\"}"
        f.llm.answerChunks.set([trailingOutput ? done + "\n" + done + "\n{" : done])
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

    @Test(arguments: [false, true])
    func rejectedUpdateKeepsCaptionCursor(malformedLine: Bool) async throws {
        let f = try await Fixture()
        try await f.makeRoom()
        let doc = try #require(CollabBackend.document.get)
        let originalOps = CollabBackend.ops.get
        let originalPrompts = f.llm.answerInputs.get.count
        let done = "{\"op\":\"done\",\"id\":\"\(doc.id)\"}"
        let tooLarge = CollabOp.replaceText(id: doc.id, field: .markdown, text: String(repeating: "大", count: 90_000))
        let line = String(decoding: try JSONEncoder().encode(tooLarge), as: UTF8.self)
        f.llm.answerChunks.set([(malformedLine ? "{" : line) + "\n" + done])
        f.clock.update { $0.addTimeInterval(90) }
        f.captions.receive(.final(String(repeating: "甲", count: 200)))
        await f.session.waitForWork()
        #expect(f.llm.answerInputs.get.count == originalPrompts + 1)
        #expect(CollabBackend.ops.get == originalOps)
        f.llm.answerChunks.set([done])
        f.clock.update { $0.addTimeInterval(90) }
        f.captions.receive(.final(String(repeating: "乙", count: 200)))
        await f.session.waitForWork()
        #expect(f.llm.answerInputs.get.count == originalPrompts + 2)
        #expect(f.llm.answerInputs.get.last?.contains("甲") == true)
        #expect(f.llm.answerInputs.get.last?.contains("乙") == true)
        #expect(CollabBackend.ops.get == originalOps)
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
        #expect(!f.session.showsCommandButton)
        CollabBackend.rejectDone.set(false)
        let prompts = f.llm.answerInputs.get.count
        f.session.retry()
        await f.session.waitForWork()
        #expect(f.session.showsCommandButton)
        #expect(f.llm.answerInputs.get.count == prompts)
        #expect(CollabBackend.ops.get.last == .done(id: previous))
        await f.session.end()?.value
    }

    @Test(arguments: [false, true])
    func cleanupReusesAppliedBatchAfterLostResponses(signInAgain: Bool) async throws {
        let f = try await Fixture()
        try await f.makeRoom()
        let original = try #require(CollabBackend.document.get)
        let modelGate = Gate<Bool>()
        defer { Task { await modelGate.open(true) } }
        f.llm.holds.set(["answer": modelGate])
        f.llm.failsStream.set(true)
        f.llm.answerChunks.set(["{\"op\":\"appendText\",\"id\":\"\(original.id)\",\"field\":\"markdown\",\"text\":\"變更\"}\n"])
        f.session.run(command: "修改既有文件")
        try #require(await eventually { CollabBackend.document.get?.content == "變更" })
        CollabBackend.doneBodies.set([])
        CollabBackend.dropDoneResponse.set(true)
        await modelGate.open(true)
        await f.session.waitForWork()
        let lostResponses = CollabBackend.doneBodies.get
        #expect(lostResponses.count == 3)
        let firstBody = try #require(lostResponses.first)
        #expect(CollabBackend.document.get?.rev == original.rev + 1)
        #expect(f.session.commandStatus == .failed(.service(.unreachable)))

        CollabBackend.dropDoneResponse.set(false)
        if signInAgain {
            CollabBackend.expired.set(true)
            await #expect(throws: CollabError.notSignedIn) { try await f.account.service.me() }
            try #require(await eventually { f.session.room == nil && f.account.user == nil })
            try await f.account.completeSignIn(code: "fixture", verifier: Fixture.verifier)
        } else {
            f.session.retry()
        }
        await f.session.waitForWork()
        #expect(CollabBackend.doneBodies.get == Array(repeating: firstBody, count: 4))
        #expect(CollabBackend.document.get?.rev == original.rev + 1)
        #expect(f.session.showsCommandButton)
    }

    @Test(arguments: [false, true])
    func lostModelDoneBatchResponseReplaysOriginalModificationAndDoneOnlyOnce(malformedReply: Bool) async throws {
        let f = try await Fixture()
        try await f.makeRoom()
        let original = try #require(CollabBackend.document.get)
        let change = CollabOp.appendText(id: original.id, field: .markdown, text: "變更")
        let done = CollabOp.done(id: original.id)
        let lines = try [change, done].map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        f.llm.answerChunks.set([lines.joined(separator: "\n") + "\n"])
        CollabBackend.doneBodies.set([])
        CollabBackend.dropDoneResponse.set(true)
        CollabBackend.malformedDoneResponse.set(malformedReply)
        f.session.run(command: "修改既有文件")
        await f.session.waitForWork()
        let expectedError: CollabError = malformedReply ? .server(status: 200) : .unreachable
        #expect(f.session.commandStatus == .failed(.service(expectedError)))

        let first = try #require(CollabBackend.doneBodies.get.first)
        let originalBatch = try JSONDecoder().decode(CollabBackend.Batch.self, from: first)
        #expect(originalBatch.ops == [change, done])
        CollabBackend.dropDoneResponse.set(false)
        f.session.retry()
        await f.session.waitForWork()
        #expect(f.session.commandStatus == .hidden)
        #expect(CollabBackend.doneBodies.get == Array(repeating: first, count: 4))
        #expect(CollabBackend.document.get?.content == original.content + "變更")
        #expect(CollabBackend.document.get?.rev == original.rev + 1)
    }

    @Test(arguments: [409, 503])
    func retainedBatchRejectionOnlyUnblocksCommandsForClientErrors(status: Int) async throws {
        let f = try await Fixture()
        try await f.makeRoom()
        let document = try #require(CollabBackend.document.get)
        let ops: [CollabOp] = [.replaceText(id: document.id, field: .markdown, text: "更新"), .done(id: document.id)]
        f.llm.answerChunks.set([try ops.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n")])
        CollabBackend.doneBodies.set([])
        CollabBackend.doneRejection.set(503)
        f.session.run(command: "第一次修改")
        await f.session.waitForWork()
        #expect(CollabBackend.doneBodies.get.count == 3)

        let firstBody = try #require(CollabBackend.doneBodies.get.first)
        CollabBackend.doneRejection.set(status)
        f.session.retry()
        await f.session.waitForWork()
        #expect(f.session.commandStatus == .failed(.service(.server(status: status))))
        let replayBodies = CollabBackend.doneBodies.get
        #expect(replayBodies == Array(repeating: firstBody, count: status == 409 ? 4 : 6))

        CollabBackend.doneRejection.set(nil)
        let before = f.llm.answerInputs.get.count
        f.session.run(command: "下一次修改")
        await f.session.waitForWork()
        if status == 409 {
            #expect(f.llm.answerInputs.get.count == before + 1)
            #expect(CollabBackend.doneBodies.get.count == replayBodies.count + 1)
            #expect(CollabBackend.document.get?.content == "更新")
        } else {
            #expect(f.llm.answerInputs.get.count == before)
            #expect(CollabBackend.doneBodies.get == replayBodies)
        }
    }

    @Test func foregroundGenerationExposesTheHostedPlanQuotaError() async throws {
        let f = try await Fixture()
        try await f.makeRoom()
        let error = ProviderError(.mm2tPlan, .outOfCredit)
        f.llm.answerChunks.set([])
        f.llm.providerStreamError.set(error)
        f.session.run(command: "新增結論")
        await f.session.waitForWork()
        #expect(f.session.commandStatus == .failed(.provider(error)))
        #expect(error.description == "Your mm2t plan has no minutes left this month.")
    }

    @Test func retryResumesTheForegroundCommandAfterARejectedBackgroundReplay() async throws {
        let f = try await Fixture()
        try await f.makeRoom()
        let document = try #require(CollabBackend.document.get)
        let ops: [CollabOp] = [.replaceText(id: document.id, field: .markdown, text: "更新"), .done(id: document.id)]
        f.llm.answerChunks.set([try ops.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n")])
        CollabBackend.doneBodies.set([])
        CollabBackend.doneRejection.set(503)
        f.clock.update { $0.addTimeInterval(100) }
        f.captions.receive(.final(String(repeating: "甲", count: 200)))
        await f.session.waitForWork()
        let before = f.llm.answerInputs.get.count
        let batch = try #require(CollabBackend.doneBodies.get.first)

        f.session.run(command: "接續指令")
        await f.session.waitForWork()
        #expect(f.session.commandStatus == .failed(.service(.server(status: 503))))
        #expect(f.llm.answerInputs.get.count == before)
        let attempts = CollabBackend.doneBodies.get.count
        #expect(CollabBackend.doneBodies.get == Array(repeating: batch, count: 6))

        CollabBackend.doneRejection.set(nil)
        f.session.retry()
        await f.session.waitForWork()
        #expect(CollabBackend.doneBodies.get.dropFirst(attempts).first == batch)
        #expect(f.llm.answerInputs.get.count == before + 1)
        #expect(f.llm.answerInputs.get.last?.contains("接續指令") == true)
    }

    @Test(arguments: [false, true])
    func nextTriggerReplaysBackgroundBatchBeforeGenerating(foreground: Bool) async throws {
        let f = try await Fixture()
        try await f.makeRoom()
        let document = try #require(CollabBackend.document.get)
        let ops: [CollabOp] = [.replaceText(id: document.id, field: .markdown, text: "更新"), .done(id: document.id)]
        f.llm.answerChunks.set([try ops.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n")])
        CollabBackend.doneBodies.set([])
        CollabBackend.dropDoneResponse.set(true)
        f.clock.update { $0.addTimeInterval(100) }
        f.captions.receive(.final(String(repeating: "甲", count: 200)))
        await f.session.waitForWork()
        let firstBody = try #require(CollabBackend.doneBodies.get.first)
        #expect(CollabBackend.doneBodies.get == Array(repeating: firstBody, count: 3))
        #expect(try JSONDecoder().decode(CollabBackend.Batch.self, from: firstBody).ops == ops)

        let before = f.llm.answerInputs.get.count
        CollabBackend.dropDoneResponse.set(false)
        CollabBackend.holdOps.set(true)
        defer {
            CollabBackend.holdOps.set(false)
            CollabBackend.releaseOps()
        }
        if foreground { f.session.run(command: "接續指令") }
        else { f.captions.receive(.final("乙")) }
        try #require(await waitForCollabEvent { CollabBackend.deferredReply.get != nil })
        #expect(CollabBackend.doneBodies.get == Array(repeating: firstBody, count: 4))
        #expect(f.llm.answerInputs.get.count == before)
        CollabBackend.holdOps.set(false)
        CollabBackend.releaseOps()
        await f.session.waitForWork()
        if foreground {
            #expect(f.llm.answerInputs.get.count == before + 1)
        } else {
            #expect(!f.llm.answerInputs.get.dropFirst(before).contains { $0.contains("\"component\":") })
            #expect(CollabBackend.doneBodies.get.count == 4)
        }
    }

    @Test(arguments: [false, true])
    func modelPromptAndItemPatchesUseExactUTF8IDsFromRoomSnapshot(hasBothIDs: Bool) async throws {
        let f = try await Fixture()
        try await f.makeRoom()
        let second = hasBothIDs ? #", "é":{"id":"é","label":"Second","shape":"ellipse"}"# : ""
        CollabBackend.extraComponent.set("""
        {"id":"board","kind":"whiteboard","title":"Board","source":"command","building":false,
         "updatedAt":"1970-01-01T00:17:00Z","nodes":{"é":{"id":"é","label":"First","shape":"box"}\(second)}}
        """)
        let before = CollabBackend.ops.get.count
        f.llm.answerChunks.set(["""
        {"op":"upsertItem","id":"board","collection":"nodes","item":{"id":"e\u{301}","label":"Second patch"}}
        {"op":"upsertItem","id":"board","collection":"nodes","item":{"id":"é","label":"First patch"}}
        {"op":"done","id":"board"}
        """])
        f.session.run(command: "Update nodes")
        await f.session.waitForWork()
        let prompt = try #require(f.llm.answerInputs.get.last)
        let input = try JSONDecoder().decode([String: CollabJSON].self, from: Data(prompt.utf8))
        guard case .array(let components) = input["components"],
              case .object(let board) = components.first(where: {
                  if case .object(let fields) = $0 { fields["id"] == .string("board") } else { false }
              }), case .array(let nodes) = board["nodes"] else {
            Issue.record("Missing whiteboard nodes in model input")
            return
        }
        let labels = nodes.compactMap { node -> (Data, String)? in
            guard case .object(let fields) = node, case .string(let id) = fields["id"],
                  case .string(let label) = fields["label"] else { return nil }
            return (Data(id.utf8), label)
        }
        let expected = hasBothIDs ? [Data("é".utf8): "First", Data("e\u{301}".utf8): "Second"] : [Data("é".utf8): "First"]
        #expect(nodes.count == expected.count)
        #expect(labels.count == expected.count)
        #expect(labels.allSatisfy { expected[$0.0] == $0.1 })
        #expect(Set(labels.map(\.0)) == Set(expected.keys))
        let ids = CollabBackend.ops.get.dropFirst(before).compactMap { op -> Data? in
            guard case .upsertItem(_, .nodes, let item) = op, case .string(let id) = item["id"] else { return nil }
            return Data(id.utf8)
        }
        #expect(ids == (hasBothIDs ? [Data("e\u{301}".utf8), Data("é".utf8)] : [Data("é".utf8)]))
        #expect(f.session.commandStatus == .completed("Board"))
    }

    @Test func malformedRemoveDoesNotDeleteComponentOrDiscardLaterUpdates() async throws {
        let f = try await Fixture()
        try await f.makeRoom()
        let id = try #require(CollabBackend.document.get?.id)
        let before = CollabBackend.ops.get.count
        f.llm.answerChunks.set(["""
        {"op":"remove","id":"\(id)","collection":"rows","itemId":"row"}
        {"op":"replaceText","id":"\(id)","field":"markdown","text":"kept"}
        {"op":"done","id":"\(id)"}
        """])
        f.session.run(command: "Update document")
        await f.session.waitForWork()
        #expect(CollabBackend.document.get?.content == "kept")
        #expect(Array(CollabBackend.ops.get.dropFirst(before)) == [
            .replaceText(id: id, field: .markdown, text: "kept"), .done(id: id),
        ])
    }

    @Test func oversizedGraphemeSplitsOnScalarBoundariesWithoutChangingUTF8() async throws {
        let f = try await Fixture()
        let grapheme = "e" + String(repeating: "\u{301}", count: 150_000)
        try #require(grapheme.count == 1)
        let text = "prefix\n" + grapheme + " suffix"
        let op = CollabOp.appendText(id: "model-id", field: .markdown, text: text)
        let line = String(decoding: try JSONEncoder().encode(op), as: UTF8.self)
        f.llm.answerChunks.set(Fixture.create + [line + "\n", Fixture.done])
        f.begin()
        try #require(await eventually { f.session.commandStatus == .completed("會議決議") })
        let parts = CollabBackend.ops.get.compactMap { op -> String? in
            if case .appendText(_, _, let text) = op { return text }
            return nil
        }
        #expect(parts.count > 1)
        #expect(Data(parts.joined().utf8) == Data(text.utf8))
        #expect(CollabBackend.opBodySizes.get.allSatisfy { $0 <= 262_144 })
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

    @Test(arguments: ["nodes", "edges", "options", "tasks", "rows"])
    func itemSchemaFixturesDiscardInvalidLinesAndSendFollowingValidOps(_ collection: String) async throws {
        let f = try await Fixture()
        let (kind, complete, patch, invalid): (String, String, String, [String]) = switch collection {
        case "nodes": ("whiteboard", #"{"id":"item","label":"A","shape":"box"}"#, #"{"id":"item","label":"B"}"#, [
            #"{"id":"item","label":"A"}"#, #"{"id":"item","label":"A","shape":"box","unknown":true}"#,
        ])
        case "edges": ("whiteboard", #"{"id":"item","from":"a","to":"b"}"#, #"{"id":"item","label":"B"}"#, [
            #"{"id":"item","from":"a"}"#, #"{"id":"item","from":"","to":"b"}"#,
        ])
        case "options": ("poll", #"{"id":"item","label":"A"}"#, #"{"id":"item"}"#, [
            #"{"id":"","label":"A"}"#, #"{"id":"item","label":"A","unknown":true}"#,
        ])
        case "tasks": ("gantt", #"{"id":"item","name":"A","start":"2024-02-29","end":"2024-03-01","dependsOn":["a"],"progress":0.5}"#,
                        #"{"id":"item","name":"B"}"#, [
            #"{"id":"item","name":"A","start":"2024-02-29","end":"2024-03-01","progress":0}"#,
            #"{"id":"item","name":"A","start":"2024-02-29","end":"2024-03-01","dependsOn":[]}"#,
            #"{"id":"item","start":"1900-02-29"}"#, #"{"id":"item","dependsOn":[""]}"#,
        ])
        default: ("actions", #"{"id":"item","task":"A","status":"open"}"#, #"{"id":"item","task":"B"}"#, [
            #"{"id":"item","task":"A"}"#, #"{"id":"item","due":"2026-04-31"}"#,
        ])
        }
        func line(_ item: String) -> String {
            """
            {"op":"upsertItem","id":"model-id","collection":"\(collection)","item":\(item)}
            """
        }
        let create = """
        {"op":"create","id":"model-id","kind":"\(kind)","title":"Test","source":"command"}
        """
        let remove = """
        {"op":"removeItem","id":"model-id","collection":"\(collection)","itemId":"item"}
        """
        let emptyRemove = remove.replacingOccurrences(of: #""itemId":"item""#, with: #""itemId":"""#)
        f.llm.answerChunks.set([([create, line(patch)] + invalid.map(line)
            + [line(complete), line(patch), emptyRemove, remove, line(patch), Fixture.done]).joined(separator: "\n")])
        f.begin()
        try #require(await eventually { f.session.commandStatus == .completed("Test") })
        let sent = CollabBackend.ops.get
        let target = try #require(sent.first?.id)
        let expected = try [create, line(complete), line(patch), remove, Fixture.done].map {
            try JSONDecoder().decode(CollabOp.self, from: Data($0.utf8)).targeting(target)
        }
        #expect(sent == expected)
        await f.session.end()?.value
    }

    @Test func invalidItemDoesNotSelectWrongTargetAndSnapshotItemsAllowPartialUpdates() throws {
        func component(_ id: String) throws -> CollabComponent {
            let json = """
            {"id":"\(id)","kind":"actions","title":"待辦","source":"command","building":false,
             "updatedAt":"2026-11-20T12:00:00Z","rows":{"existing":{"id":"existing","task":"聯絡","status":"open"}}}
            """
            return try JSONDecoder().decode(CollabComponent.self, from: Data(json.utf8))
        }
        var route = CollabGeneration(components: try [component("first"), component("second")], newID: "new", source: .command)
        let invalid = try JSONDecoder().decode(CollabOp.self, from: Data(
            #"{"op":"upsertItem","id":"first","collection":"rows","item":{"id":"missing"}}"#.utf8))
        let valid = try JSONDecoder().decode(CollabOp.self, from: Data(
            #"{"op":"upsertItem","id":"second","collection":"rows","item":{"id":"existing","status":"done"}}"#.utf8))
        #expect(try route.accept(invalid) == nil)
        #expect(route.target == nil)
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

    private func waitForCollabEvent(until timeout: Duration = .seconds(3), _ event: @MainActor () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline, !Task.isCancelled {
            if await event() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
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
                                                webURL: URL(string: "https://web.collab.invalid")!,
                                                accountURL: URL(string: "https://account.invalid/account/")!)

        init(waitOnRetry: @escaping @Sendable () async -> Void = {},
             pendingEndsWrite: @escaping @Sendable (Data, URL) throws -> Void = CollabPendingEnds.writeAtomically) async throws {
            CollabBackend.reset()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [CollabBackend.self]
            http = URLSession(configuration: config)
            pendingFile = try temporaryDirectory().appending(path: "pending.json")
            account = CollabAccount(configuration: configuration, credentials: credentials, pendingEndsFile: pendingFile,
                                    session: http, endRetrySleep: { [retryDelays] delay in
                retryDelays.update { $0.append(delay) }
                await waitOnRetry()
            }, pendingEndsWrite: pendingEndsWrite)
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
        var rev = 0
        var content = ""
    }

    static let requests = Box<[String]>([])
    static let quotaUsed = Box(0)
    static let planUsedSeconds = Box<Int?>(nil)
    static let planName = Box("pro")
    static let blockRoomCreation = Box(false)
    static let handoffURL = Box<String?>(nil)
    static let profileUnavailable = Box(false)
    static let holdNextProfile = Box(false)
    static let deferredProfile = Box<(@Sendable () -> Void)?>(nil)
    static let document = Box<Document?>(nil)
    static let extraComponent = Box<String?>(nil)
    static let appliedBatches = Box<Set<UUID>>([])
    static let doneBodies = Box<[Data]>([])
    static let opBodySizes = Box<[Int]>([])
    static let dropDoneResponse = Box(false)
    static let malformedDoneResponse = Box(false)
    static let events = Box<[String]>([])
    static let ops = Box<[CollabOp]>([])
    static let offlineEnd = Box(false)
    static let exchanges = Box<[[String: String]]>([])
    static let roomEnded = Box(false)
    static let doneRejection = Box<Int?>(nil)
    static let rejectDone = Box(false)
    static let expired = Box(false)
    static let endBearers = Box<[String]>([])
    static let holdOps = Box(false)
    static let holdCreation = Box(false)
    static let deferredCreation = Box<(@Sendable () -> Void)?>(nil)
    static let deferredReply = Box<(@Sendable () -> Void)?>(nil)

    static func reset() {
        quotaUsed.set(0); planUsedSeconds.set(nil); planName.set("pro"); handoffURL.set(nil)
        blockRoomCreation.set(false)
        profileUnavailable.set(false); holdNextProfile.set(false); deferredProfile.set(nil)
        exchanges.set([]); requests.set([]); document.set(nil); events.set([]); ops.set([]); endBearers.set([])
        extraComponent.set(nil); appliedBatches.set([]); doneBodies.set([]); opBodySizes.set([]); dropDoneResponse.set(false); malformedDoneResponse.set(false)
        offlineEnd.set(false); roomEnded.set(false); rejectDone.set(false); doneRejection.set(nil); expired.set(false); holdOps.set(false); deferredReply.set(nil)
        holdCreation.set(false); deferredCreation.set(nil)
    }

    static func releaseProfile() {
        var reply: (@Sendable () -> Void)?
        deferredProfile.update { reply = $0; $0 = nil }
        reply?()
    }

    static func releaseCreation() {
        holdCreation.set(false)
        var reply: (@Sendable () -> Void)?
        deferredCreation.update { reply = $0; $0 = nil }
        reply?()
    }

    static func releaseOps() {
        var reply: (@Sendable () -> Void)?
        deferredReply.update { reply = $0; $0 = nil }
        reply?()
    }

    struct Batch: Decodable { let batchId: UUID; let ops: [CollabOp] }

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
            let plan = Self.planUsedSeconds.get.map {
                #", "plan":{"name":"\#(Self.planName.get)","status":"active","period":{"start":"2026-11-01T00:00:00.000Z","end":"2026-12-01T00:00:00.000Z"},"minutes":{"limit":900,"usedSeconds":\#($0)},"ai":{"asksLimit":null,"asksUsed":4},"storedMeetings":{"limit":200}}"#
            } ?? ""
            response = Self.profileUnavailable.get ? (503, Data()) : (200, Data(
                "{\"user\":\(user),\"quota\":{\"used\":\(Self.quotaUsed.get),\"limit\":10,\"period\":\"2026-11\"}\(plan)}".utf8))
            var hold = false
            Self.holdNextProfile.update { hold = $0; $0 = false }
            if hold {
                let (status, body) = response
                Self.deferredProfile.set { [self] in reply(status: status, body: body) }
                return
            }
        case "/v1/billing/handoff":
            if let handoffURL = Self.handoffURL.get {
                response = (200, Data(#"{"url":"\#(handoffURL)"}"#.utf8))
            } else {
                response = (503, Data(#"{"error":"billing_unavailable"}"#.utf8))
            }
        case "/v1/rooms":
            if Self.blockRoomCreation.get {
                reply(status: 403, body: Data(#"{"error":"plan_required"}"#.utf8))
                return
            }
            let body = Data(#"{"roomId":"room","shareUrl":"https://web.collab.invalid/r/share","hostUrl":"https://web.collab.invalid/r/share#host=code"}"#.utf8)
            if Self.holdCreation.get {
                Self.deferredCreation.set { [self] in reply(status: 201, body: body) }
                if !Self.holdCreation.get { Self.releaseCreation() }
                return
            }
            response = (201, body)
        case "/v1/rooms/room/components":
            let doc = Self.document.get.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
            let json = [doc, Self.extraComponent.get].compactMap { $0 }.joined(separator: ",")
            response = (200, Data("{\"status\":\"live\",\"components\":[\(json)]}".utf8))
        case "/v1/rooms/room/ops":
            Self.events.update { $0.append("ops-start") }
            if Self.roomEnded.get {
                reply(status: 409, body: Data(#"{"error":"room_ended"}"#.utf8))
                return
            }
            let wireBody = body()
            Self.opBodySizes.update { $0.append(wireBody.count) }
            guard let batch = try? JSONDecoder().decode(Batch.self, from: wireBody) else {
                reply(status: 400, body: Data()); return
            }
            Self.ops.update { $0 += batch.ops }
            let hasDone = batch.ops.contains { if case .done = $0 { true } else { false } }
            if hasDone { Self.doneBodies.update { $0.append(wireBody) } }
            if hasDone, let status = Self.doneRejection.get ?? (Self.rejectDone.get ? 503 : nil) {
                reply(status: status, body: Data())
                return
            }
            var duplicate = false
            Self.appliedBatches.update { duplicate = !$0.insert(batch.batchId).inserted }
            if !duplicate { Self.apply(batch.ops) }
            if hasDone, Self.dropDoneResponse.get {
                if Self.malformedDoneResponse.get { reply(status: 200, body: Data()) }
                else { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
                return
            }
            let finish: @Sendable () -> Void = { [self, duplicate] in
                Self.events.update { $0.append("ops-complete") }
                reply(status: 200, body: Data("{\"applied\":\(batch.ops.count),\"duplicate\":\(duplicate)}".utf8))
            }
            if Self.holdOps.get {
                Self.deferredReply.set(finish)
                if !Self.holdOps.get { Self.releaseOps() }
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

    private static func apply(_ ops: [CollabOp]) {
        document.update { document in
            for op in ops {
                if case .create(let id, _, let title, let source) = op {
                    document = Document(id: id, title: title, source: source)
                    continue
                }
                guard document?.id == op.id else { continue }
                switch op {
                case .appendText(_, _, let text): document?.content += text
                case .replaceText(_, _, let text): document?.content = text
                case .done:
                    document?.building = false
                    document?.rev += 1
                case .remove: document = nil
                default: break
                }
            }
        }
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
