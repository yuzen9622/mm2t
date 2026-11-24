import Foundation
import MM2TCore
import MM2TProviders
import Testing

struct CollabServiceTests {
    private static let base = URL(string: "https://collab.invalid")!
    private static let login = #"{"accessToken":"a1","refreshToken":"r1","user":{"id":"u","email":"person@example.invalid","name":"Host"}}"#
    private static let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    private static let rotated = #"{"accessToken":"a2","refreshToken":"r2","user":{"id":"u","email":"person@example.invalid","name":"Updated Host"}}"#
    private static let profile = #"{"user":{"id":"u","email":"person@example.invalid","name":"Host"},"quota":{"used":3,"limit":10,"period":"2026-11"}}"#

    @Test func oauthRoomAndOperationWireShapes() async throws {
        let server = StubServer { call in
            switch call.url.path {
            case "/v1/auth/exchange": .status(200, Self.login)
            case "/v1/me": .status(200, Self.profile)
            case "/v1/rooms": .status(201, #"{"roomId":"r","shareUrl":"https://web.invalid/r/share","hostUrl":"https://web.invalid/r/share#host=code"}"#)
            case "/v1/rooms/r/components": .status(200, #"{"status":"live","components":[{"id":"doc","kind":"document","title":"Meeting","source":"command","building":false,"createdAt":"2026-11-20T11:00:00.000Z","updatedAt":"2026-11-20T12:00:00.000Z","rev":1,"content":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Text"}]}]}}]}"#)
            case "/v1/rooms/r/ops": .status(200, #"{"applied":1,"duplicate":false}"#)
            case "/v1/rooms/r/end": .status(200, #"{"status":"ended"}"#)
            case "/v1/auth/logout": .status(200, #"{"ok":true}"#)
            default: .status(500, "")
            }
        }
        let store = MemoryTokens()
        let service = store.service(using: server)
        for (provider, name) in [(CollabLoginProvider.google, "google"), (.apple, "apple")] {
            let challenge = CollabPKCE.challenge(for: Self.verifier)
            let url = service.authStartURL(provider, codeChallenge: challenge)
            #expect(url.path == "/v1/auth/\(name)/start")
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [
                .init(name: "redirect", value: "mm2t://auth"), .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
            ])
        }
        #expect(try await service.exchange(code: "one-time", codeVerifier: Self.verifier).name == "Host")
        let profile = try await service.me()
        #expect(profile.plan == nil)
        let quota = profile.quota
        #expect(quota.used == 3 && quota.limit == 10 && quota.period == "2026-11")
        let room = try await service.createRoom(title: "會議", owner: "u", aiSource: .own)
        #expect(room.roomId == "r" && room.shareUrl.absoluteString == "https://web.invalid/r/share" && room.hostUrl.fragment == "host=code")
        let components = try await service.components(in: room.roomId, owner: "u")
        let document = try #require(components.components.first)
        #expect(document.updatedAt == "2026-11-20T12:00:00.000Z")
        #expect(document.fields["content"] == .object([
            "type": .string("doc"), "content": .array([.object([
                "type": .string("paragraph"), "content": .array([.object(["type": .string("text"), "text": .string("Text")])]),
            ])]),
        ]))
        let batch = CollabOpBatch([.done(id: "doc")])
        let result = try await service.sendOps(batch, to: room.roomId, owner: "u")
        #expect(result.applied == 1 && !result.duplicate)
        try await service.endRoom(room.roomId, owner: "u")
        try await service.endRoom(room.roomId, owner: "u")
        try await service.logout()
        #expect(store.saved?.isEmpty == true)
        await #expect(throws: CollabError.notSignedIn) { try await service.me() }
        let calls = server.requests
        #expect(calls.map(\.url.path) == ["/v1/auth/exchange", "/v1/me", "/v1/rooms", "/v1/rooms/r/components", "/v1/rooms/r/ops", "/v1/rooms/r/end", "/v1/rooms/r/end", "/v1/auth/logout"])
        #expect(calls.map(\.method) == ["POST", "GET", "POST", "GET", "POST", "POST", "POST", "POST"])
        #expect(calls[0].headers["Authorization"] == nil)
        #expect(calls.dropFirst().dropLast().allSatisfy { $0.headers["Authorization"] == "Bearer a1" })
        #expect(calls.allSatisfy { $0.headers["Accept"] == "application/json" })
        let json = JSONDecoder()
        #expect(try json.decode([String: String].self, from: calls[0].body) == ["code": "one-time", "codeVerifier": Self.verifier])
        #expect(calls[7].headers["Authorization"] == nil)
        #expect(try json.decode([String: String].self, from: calls[7].body) == ["refreshToken": "r1"])
        #expect(try json.decode([String: String].self, from: calls[2].body) == ["title": "會議", "aiSource": "own"])
        let wire = try json.decode(OpWire.self, from: calls[4].body)
        #expect(wire.batchId == batch.batchId)
        #expect(wire.ops == [.done(id: "doc")])
        #expect(calls[4].headers["Content-Type"] == "application/json")
        #expect(calls[1].body.isEmpty && calls[3].body.isEmpty && calls[5].body.isEmpty && calls[6].body.isEmpty)
    }

    @Test(arguments: [false, true])
    func profileDecodesPlanForKnownAndUnknownValues(scheduled: Bool) async throws {
        let change = scheduled ? #"{"plan":"free","at":"2026-12-01T00:00:00.125Z"}"# : "null"
        let status = scheduled ? "future_status" : "active"
        let name = scheduled ? "future_plan" : "pro"
        let plan = #"{"name":"\#(name)","status":"\#(status)","period":{"start":"2026-11-01T00:00:00.000Z","end":"2026-12-01T00:00:00.000Z"},"minutes":{"limit":900,"usedSeconds":18720},"ai":{"asksLimit":null,"asksUsed":4},"storedMeetings":{"limit":200},"scheduledChange":\#(change)}"#
        let profile = String(Self.profile.dropLast()) + #", "plan":\#(plan)}"#
        let server = StubServer { call in
            switch call.url.path {
            case "/v1/auth/exchange": .status(200, Self.login)
            case "/v1/me": .status(200, profile)
            default: .status(500, "")
            }
        }
        let service = MemoryTokens().service(using: server)
        _ = try await service.exchange(code: "code", codeVerifier: Self.verifier)
        let result = try await service.me()
        let decoded = try #require(result.plan)
        let periodEnd = Date(timeIntervalSince1970: 1_796_083_200)
        #expect(result.user.id == "u")
        #expect(decoded.name == name && decoded.status == status)
        #expect(decoded.periodEnd == periodEnd)
        #expect(decoded.minutesLimit == 900 && decoded.usedSeconds == 18720)
        #expect(decoded.asksLimit == nil && decoded.asksUsed == 4)
        if scheduled {
            #expect(decoded.scheduledChange?.plan == "free")
            #expect(decoded.scheduledChange?.at == periodEnd.addingTimeInterval(0.125))
        } else {
            #expect(decoded.scheduledChange == nil)
        }
    }

    @Test func profileIgnoresPlanMissingPeriod() async throws {
        let plan = #"{"name":"pro","status":"active","minutes":{"limit":900,"usedSeconds":18720},"ai":{"asksLimit":null,"asksUsed":4}}"#
        let profile = String(Self.profile.dropLast()) + #", "plan":\#(plan)}"#
        let server = StubServer { call in
            switch call.url.path {
            case "/v1/auth/exchange": .status(200, Self.login)
            case "/v1/me": .status(200, profile)
            default: .status(500, "")
            }
        }
        let service = MemoryTokens().service(using: server)
        let user = try await service.exchange(code: "code", codeVerifier: Self.verifier)
        let result = try await service.me()
        #expect(result.user == user)
        #expect(result.quota.used == 3 && result.quota.limit == 10 && result.quota.period == "2026-11")
        #expect(result.plan == nil)
    }

    @Test(arguments: [false, true])
    func billingHandoffPostsWithoutBodyAndRenewsOnlyOnUnauthorized(renew: Bool) async throws {
        let body = #"{"url":"https://web.invalid/account#handoff=code","expiresAt":"2026-12-01T00:00:00.000Z"}"#
        let server = StubServer { call in
            switch call.url.path {
            case "/v1/auth/exchange": .status(200, Self.login)
            case "/v1/auth/refresh": .status(200, Self.rotated)
            case "/v1/billing/handoff" where renew && call.headers["Authorization"] == "Bearer a1": .status(401, "")
            case "/v1/billing/handoff": .status(200, body)
            default: .status(500, "")
            }
        }
        let service = MemoryTokens().service(using: server)
        _ = try await service.exchange(code: "code", codeVerifier: Self.verifier)
        #expect(try await service.billingHandoff().absoluteString == "https://web.invalid/account#handoff=code")
        let calls = server.requests
        let handoff = "/v1/billing/handoff"
        #expect(calls.map(\.url.path) == ["/v1/auth/exchange", handoff] + (renew ? ["/v1/auth/refresh", handoff] : []))
        let handoffs = calls.filter { $0.url.path == handoff }
        #expect(handoffs.allSatisfy { $0.method == "POST" && $0.body.isEmpty })
        #expect(handoffs.map { $0.headers["Authorization"] } == (renew ? ["Bearer a1", "Bearer a2"] : ["Bearer a1"]))
    }

    @Test func refreshRotatesCredentialsAndRetryOnlyOnce() async throws {
        let server = StubServer { call in
            switch call.url.path {
            case "/v1/auth/exchange": .status(200, Self.login)
            case "/v1/auth/refresh": .status(200, Self.rotated)
            case "/v1/me" where call.headers["Authorization"] == "Bearer a2": .status(200, Self.profile)
            default: .status(401, "")
            }
        }
        let store = MemoryTokens()
        let service = store.service(using: server)
        _ = try await service.exchange(code: "code", codeVerifier: Self.verifier)
        #expect(try await service.me().user.id == "u")
        let calls = server.requests
        #expect(calls.map(\.url.path) == ["/v1/auth/exchange", "/v1/me", "/v1/auth/refresh", "/v1/me"])
        #expect(calls[1].headers["Authorization"] == "Bearer a1")
        #expect(try JSONDecoder().decode([String: String].self, from: calls[2].body) == ["refreshToken": "r1"])
        #expect(calls[2].headers["Authorization"] == nil)
        #expect(calls[3].headers["Authorization"] == "Bearer a2")
        let restored = store.service(using: server)
        #expect(try await restored.me().quota.limit == 10)
        let last = try #require(server.requests.last)
        #expect(last.headers["Authorization"] == "Bearer a2")
    }

    @Test func concurrentUnauthorizedRequestsShareOneRefresh() async throws {
        let gate = ResponseGate()
        defer { gate.open() }
        let server = StubServer { call in
            switch call.url.path {
            case "/v1/auth/exchange": .status(200, Self.login)
            case "/v1/auth/refresh": .after { await gate.wait() ? (200, Self.rotated) : (503, "") }
            case "/v1/rooms/r/components" where call.headers["Authorization"] == "Bearer a2":
                .status(200, #"{"status":"live","components":[]}"#)
            case "/v1/rooms/r/components": .status(401, "")
            default: .status(500, "")
            }
        }
        let store = MemoryTokens()
        let service = store.service(using: server)
        _ = try await service.exchange(code: "code", codeVerifier: Self.verifier)
        let first = Task { try await service.components(in: "r", owner: "u") }
        let second = Task { try await service.components(in: "r", owner: "u") }
        defer { first.cancel(); second.cancel() }
        try #require(await waitForRequests {
            server.requests.filter { $0.url.path.hasSuffix("/components") }.count == 2
                && server.requests.contains { $0.url.path == "/v1/auth/refresh" }
        })
        gate.open()
        let results = try await [first.value, second.value]
        #expect(results.allSatisfy { $0.status == .live })
        let refresh = server.requests.filter { $0.url.path == "/v1/auth/refresh" }
        try #require(refresh.count == 1)
        #expect(try JSONDecoder().decode([String: String].self, from: refresh[0].body) == ["refreshToken": "r1"])
        let ops = server.requests.filter { $0.url.path.hasSuffix("/components") }
        #expect(ops.compactMap { $0.headers["Authorization"] } == ["Bearer a1", "Bearer a1", "Bearer a2", "Bearer a2"])
        let stored = try #require(store.saved)
        let value = try JSONDecoder().decode(StoredLogin.self, from: Data(stored.revealed.utf8))
        #expect(value.tokens.refreshToken == "r2")
        #expect(value.user.name == "Updated Host")
        #expect(await service.signedInUser == value.user)
    }

    @Test func cancelledRefreshWaiterDoesNotRetryOrCancelSharedRotation() async throws {
        let gate = ResponseGate()
        defer { gate.open() }
        let server = StubServer { call in
            switch call.url.path {
            case "/v1/auth/exchange": .status(200, Self.login)
            case "/v1/auth/refresh": .after { await gate.wait() ? (200, Self.rotated) : (503, "") }
            case "/v1/rooms/kept/components" where call.headers["Authorization"] == "Bearer a2":
                .status(200, #"{"status":"live","components":[]}"#)
            default: .status(401, "")
            }
        }
        let store = MemoryTokens()
        let service = store.service(using: server)
        _ = try await service.exchange(code: "code", codeVerifier: Self.verifier)
        let cancelled = Task { try await service.components(in: "cancelled", owner: "u") }
        defer { cancelled.cancel() }
        try #require(await waitForRequests { server.requests.contains { $0.url.path == "/v1/auth/refresh" } })
        let kept = Task { try await service.components(in: "kept", owner: "u") }
        defer { kept.cancel() }
        try #require(await waitForRequests { server.requests.contains { $0.url.path == "/v1/rooms/kept/components" } })
        cancelled.cancel()
        gate.open()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await kept.value.status == .live)
        #expect(server.requests.filter { $0.url.path == "/v1/auth/refresh" }.count == 1)
        #expect(server.requests.filter { $0.url.path == "/v1/rooms/cancelled/components" }.map { $0.headers["Authorization"] } == ["Bearer a1"])
        let stored = try #require(store.saved)
        let value = try JSONDecoder().decode(StoredLogin.self, from: Data(stored.revealed.utf8))
        #expect(value.tokens.refreshToken == "r2")
    }

    private func waitForRequests(_ event: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while clock.now < deadline, !Task.isCancelled {
            if event() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    private final class ResponseGate: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        func open() { lock.withLock { released = true } }
        func wait() async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(5)
            while clock.now < deadline, !Task.isCancelled {
                if lock.withLock({ released }) { return true }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return false
        }
    }

    @Test(arguments: [401, 503]) func logoutClearsLocalCredentialsOnFailure(status: Int) async throws {
        let server = StubServer { call in
            call.url.path == "/v1/auth/exchange" ? .status(200, Self.login) : .status(status, "")
        }
        let store = MemoryTokens()
        let service = store.service(using: server)
        _ = try await service.exchange(code: "code", codeVerifier: Self.verifier)
        await #expect(throws: status == 401 ? CollabError.notSignedIn : .server(status: status)) { try await service.logout() }
        #expect(await !service.isAuthenticated)
        #expect(store.saved?.isEmpty == true)
        #expect(server.requests.map(\.url.path) == ["/v1/auth/exchange", "/v1/auth/logout"])
        let call = try #require(server.requests.last)
        #expect(try JSONDecoder().decode([String: String].self, from: call.body) == ["refreshToken": "r1"])
    }

    private struct StoredLogin: Decodable {
        struct Tokens: Decodable { let refreshToken: String }
        let tokens: Tokens
        let user: CollabUser
    }

    @Test(arguments: [200, 401, 503]) func failedAuthenticationClearsStoredCredentials(refreshStatus: Int) async throws {
        let server = StubServer { call in
            switch call.url.path {
            case "/v1/auth/exchange": .status(200, Self.login)
            case "/v1/auth/refresh": .status(refreshStatus, Self.rotated)
            default: .status(401, "")
            }
        }
        let store = MemoryTokens()
        let service = store.service(using: server)
        _ = try await service.exchange(code: "code", codeVerifier: Self.verifier)
        await #expect(throws: CollabError.notSignedIn) { try await service.me() }
        #expect(store.saved?.isEmpty == true)
        let expected = ["/v1/auth/exchange", "/v1/me", "/v1/auth/refresh"] + (refreshStatus == 200 ? ["/v1/me"] : [])
        #expect(server.requests.map(\.url.path) == expected)
        await #expect(throws: CollabError.notSignedIn) { try await service.me() }
        #expect(server.requests.count == expected.count)
    }

    @Test func savedTokensAreNotSentWhenAnOverrideChangesTheAPIURL() async throws {
        let original = StubServer(status: 200, body: Self.login)
        let override = StubServer(status: 500, body: "")
        let storage = MemoryTokens()
        _ = try await storage.service(using: original).exchange(code: "code", codeVerifier: Self.verifier)
        let second = storage.service(using: override, base: URL(string: "http://override.invalid:8100")!)
        await #expect(throws: CollabError.notSignedIn) { try await second.me() }
        #expect(override.requests.isEmpty)
        #expect(storage.saved?.isEmpty == false)
    }

    @Test func statusAndTransportErrorsKeepTheirMeaning() async throws {
        let server = StubServer { call in
            switch call.url.path {
            case "/v1/auth/exchange": .status(200, Self.login)
            case "/v1/rooms": .status(429, #"{"error":"quota_exceeded","used":10,"limit":10}"#)
            case "/v1/rooms/r/ops": .status(409, #"{"error":"room_ended"}"#)
            case "/v1/rooms/r/end": .status(403, "")
            default: .failure(.notConnectedToInternet)
            }
        }
        let service = MemoryTokens().service(using: server)
        _ = try await service.exchange(code: "code", codeVerifier: Self.verifier)
        await #expect(throws: CollabError.quotaExceeded(used: 10, limit: 10)) { try await service.createRoom(title: "A", owner: "u", aiSource: .hosted) }
        await #expect(throws: CollabError.roomEnded) { try await service.sendOps(.init([.done(id: "doc")]), to: "r", owner: "u") }
        await #expect(throws: CollabError.server(status: 403)) { try await service.endRoom("r", owner: "u") }
        await #expect(throws: CollabError.unreachable) { try await service.me() }
    }

    private struct OpWire: Decodable {
        let batchId: UUID
        let ops: [CollabOp]
    }

    @Test func endedRoomDropsQueuedOpsWithoutRetrying() async throws {
        let server = StubServer { call in
            call.url.path == "/v1/auth/exchange" ? .status(200, Self.login) : .status(409, #"{"error":"room_ended"}"#)
        }
        let service = MemoryTokens().service(using: server)
        _ = try await service.exchange(code: "code", codeVerifier: Self.verifier)
        let (release, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        defer { continuation.finish() }
        let sender = CollabOpSender(sleep: { _ in try await Task.sleep(for: .seconds(30)) }) { batch in
            for await _ in release { break }
            try await service.sendOps(batch, to: "r", owner: "u")
        }
        let ops = (0..<21).map { CollabOp.done(id: "doc-\($0)") }
        for op in ops { try await sender.append(op) }
        continuation.yield(())
        continuation.finish()
        await #expect(throws: CollabError.roomEnded) { try await sender.finish() }
        await #expect(throws: CollabError.roomEnded) { try await sender.append(.done(id: "late")) }
        let calls = server.requests.filter { $0.url.path == "/v1/rooms/r/ops" }
        try #require(calls.count == 1)
        #expect(try JSONDecoder().decode(OpWire.self, from: calls[0].body).ops == Array(ops.prefix(20)))
    }

    @Test func lostResponseRetriesIdenticalBatchWithoutReapplying() async throws {
        let applied = AppliedBatches()
        let server = StubServer { call in
            if call.url.path == "/v1/auth/exchange" { return .status(200, Self.login) }
            guard let wire = try? JSONDecoder().decode(OpWire.self, from: call.body) else { return .status(400, "") }
            if applied.insert(wire.batchId) { return .failure(.networkConnectionLost) }
            return .status(200, #"{"applied":1,"duplicate":true}"#)
        }
        let service = MemoryTokens().service(using: server)
        _ = try await service.exchange(code: "code", codeVerifier: Self.verifier)
        let sender = CollabOpSender { batch in
            let result = try await service.sendOps(batch, to: "r", owner: "u")
            #expect(result.applied == 1 && result.duplicate)
        }
        try await sender.append(.appendText(id: "doc", field: .markdown, text: "只寫一次"))
        try await sender.finish()
        let calls = server.requests.filter { $0.url.path.hasSuffix("/ops") }
        try #require(calls.count == 2)
        #expect(calls[0].body == calls[1].body)
        #expect(applied.count == 1)
    }

    @Test(arguments: [false, true])
    func senderUsesExactWireByteLimit(includeSecondOp: Bool) async throws {
        let server = StubServer { call in
            if call.url.path == "/v1/auth/exchange" { return .status(200, Self.login) }
            return call.body.count <= 262_144 ? .status(200, #"{"applied":1,"duplicate":false}"#) : .status(413, "")
        }
        let service = MemoryTokens().service(using: server)
        _ = try await service.exchange(code: "code", codeVerifier: Self.verifier)
        let done = CollabOp.done(id: "doc")
        func replace(_ size: Int) -> CollabOp {
            .replaceText(id: "doc", field: .markdown, text: String(repeating: "x", count: size))
        }
        func batch(_ op: CollabOp) -> [CollabOp] { includeSecondOp ? [op, done] : [op] }
        let overhead = try JSONEncoder().encode(CollabOpBatch(batch(replace(0)))).count
        let exact = replace(262_144 - overhead)
        let over = replace(262_145 - overhead)
        let sender = CollabOpSender(sleep: { _ in try await Task.sleep(for: .seconds(60)) }) { batch in
            try await service.sendOps(batch, to: "r", owner: "u")
        }
        #expect(try await sender.append(exact))
        if includeSecondOp { try await sender.append(done) }
        try await sender.finish()
        #expect(server.requests.filter { $0.url.path.hasSuffix("/ops") }.map { $0.body.count } == [262_144])

        let next = CollabOpSender(sleep: { _ in try await Task.sleep(for: .seconds(60)) }) { batch in
            try await service.sendOps(batch, to: "r", owner: "u")
        }
        #expect(try await next.append(over) == includeSecondOp)
        if includeSecondOp { try await next.append(done) }
        try await next.finish()
        let sizes = server.requests.filter { $0.url.path.hasSuffix("/ops") }.map { $0.body.count }
        if includeSecondOp {
            #expect(sizes == [262_144, try JSONEncoder().encode(CollabOpBatch([over])).count,
                              try JSONEncoder().encode(CollabOpBatch([done])).count])
        } else { #expect(sizes == [262_144]) }
    }

    @Test(arguments: [400, 429, 503])
    func senderOnlyRetriesRecoverableHTTPStatuses(status: Int) async throws {
        let server = StubServer { call in
            call.url.path == "/v1/auth/exchange" ? .status(200, Self.login) : .status(status, "")
        }
        let service = MemoryTokens().service(using: server)
        _ = try await service.exchange(code: "code", codeVerifier: Self.verifier)
        let sender = CollabOpSender { batch in try await service.sendOps(batch, to: "r", owner: "u") }
        try await sender.append(.done(id: "doc"))
        await #expect(throws: CollabError.server(status: status)) { try await sender.finish() }
        let calls = server.requests.filter { $0.url.path.hasSuffix("/ops") }
        #expect(calls.count == (status == 400 ? 1 : 3))
        #expect(Set(calls.map(\.body)).count == 1)
    }

    @Test func senderPreservesCredentialDeletionFailureAfterRefreshInvalidatesSession() async throws {
        let server = StubServer { call in
            call.url.path == "/v1/auth/exchange" ? .status(200, Self.login) : .status(401, "")
        }
        let service = CollabService(baseURL: Self.base, session: server.session, load: { nil }, save: { secret in
            if secret.isEmpty { throw CocoaError(.fileWriteNoPermission) }
        })
        _ = try await service.exchange(code: "code", codeVerifier: Self.verifier)
        let sender = CollabOpSender { batch in try await service.sendOps(batch, to: "r", owner: "u") }
        try await sender.append(.done(id: "doc"))
        await #expect(throws: CollabError.credentialCleanup) { try await sender.finish() }
        #expect(server.requests.filter { $0.url.path.hasSuffix("/ops") }.count == 1)
        #expect(await !service.isAuthenticated)
    }

    private final class AppliedBatches: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<UUID> = []
        var count: Int { lock.withLock { ids.count } }
        func insert(_ id: UUID) -> Bool { lock.withLock { ids.insert(id).inserted } }
    }

    private final class MemoryTokens: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Secret?
        var saved: Secret? { lock.withLock { value } }
        func service(using server: StubServer, base: URL = CollabServiceTests.base) -> CollabService {
            CollabService(baseURL: base, session: server.session,
                          load: { self.saved }, save: { secret in self.lock.withLock { self.value = secret } })
        }
    }
}
