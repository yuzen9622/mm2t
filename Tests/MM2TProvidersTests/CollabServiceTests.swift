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
        let quota = try await service.me().quota
        #expect(quota.used == 3 && quota.limit == 10 && quota.period == "2026-11")
        let room = try await service.createRoom(title: "會議", owner: "u")
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
        let barrier = TwoRequests()
        let server = StubServer { call in
            switch call.url.path {
            case "/v1/auth/exchange": .status(200, Self.login)
            case "/v1/auth/refresh": .status(200, Self.rotated)
            case "/v1/rooms/r/components" where call.headers["Authorization"] == "Bearer a2":
                .status(200, #"{"status":"live","components":[]}"#)
            case "/v1/rooms/r/components": .after { await barrier.arrive(); return (401, "") }
            default: .status(500, "")
            }
        }
        let store = MemoryTokens()
        let service = store.service(using: server)
        _ = try await service.exchange(code: "code", codeVerifier: Self.verifier)
        async let first = service.components(in: "r", owner: "u")
        async let second = service.components(in: "r", owner: "u")
        let results = try await [first, second]
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

    private actor TwoRequests {
        private var first: CheckedContinuation<Void, Never>?

        func arrive() async {
            if let first {
                self.first = nil
                first.resume()
            } else {
                await withCheckedContinuation { first = $0 }
            }
        }
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
        await #expect(throws: CollabError.quotaExceeded(used: 10, limit: 10)) { try await service.createRoom(title: "A", owner: "u") }
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

    @Test func credentialDeletionFailureIsReportedAfterRefreshInvalidatesSession() async throws {
        let server = StubServer { call in
            call.url.path == "/v1/auth/exchange" ? .status(200, Self.login) : .status(401, "")
        }
        let service = CollabService(baseURL: Self.base, session: server.session, load: { nil }, save: { secret in
            if secret.isEmpty { throw CocoaError(.fileWriteNoPermission) }
        })
        _ = try await service.exchange(code: "code", codeVerifier: Self.verifier)
        await #expect(throws: CollabError.credentialCleanup) { try await service.me() }
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
