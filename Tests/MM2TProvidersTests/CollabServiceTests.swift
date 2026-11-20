import Foundation
import MM2TCore
import MM2TProviders
import Testing

struct CollabServiceTests {
    private static let base = URL(string: "https://collab.invalid")!
    private static let login = #"{"accessToken":"a1","refreshToken":"r1","user":{"id":"u","email":"person@example.invalid","name":"Host"}}"#
    private static let profile = #"{"user":{"id":"u","email":"person@example.invalid","name":"Host"},"quota":{"used":3,"limit":10,"period":"2026-11"}}"#

    @Test func oauthRoomAndOperationWireShapes() async throws {
        let server = StubServer { call in
            switch call.url.path {
            case "/v1/auth/exchange": .status(200, Self.login)
            case "/v1/me": .status(200, Self.profile)
            case "/v1/rooms": .status(201, #"{"roomId":"r","shareUrl":"https://web.invalid/r/share","hostUrl":"https://web.invalid/r/share#host=code"}"#)
            case "/v1/rooms/r/components": .status(200, #"{"status":"live","components":[{"id":"doc","kind":"document","title":"Meeting","source":"command","building":false,"updatedAt":"2026-11-20T12:00:00Z","content":"Text"}]}"#)
            case "/v1/rooms/r/ops", "/v1/rooms/r/end", "/v1/auth/logout": .status(204, "")
            default: .status(500, "")
            }
        }
        let store = MemoryTokens()
        let service = store.service(using: server)
        for (provider, name) in [(CollabLoginProvider.google, "google"), (.apple, "apple")] {
            let url = service.authStartURL(provider)
            #expect(url.path == "/v1/auth/\(name)/start")
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "redirect", value: "mm2t://auth")])
        }
        #expect(try await service.exchange(code: "one-time").name == "Host")
        #expect(try await service.me().quota.used == 3)
        let room = try await service.createRoom(title: "會議")
        #expect(room.hostUrl.fragment == "host=code")
        let components = try await service.components(in: room.roomId)
        #expect(components.components.first?.fields["content"] == .string("Text"))
        try await service.sendOps([.done(id: "doc")], to: room.roomId)
        try await service.endRoom(room.roomId)
        try await service.logout()
        #expect(store.saved?.isEmpty == true)
        await #expect(throws: CollabError.notSignedIn) { try await service.me() }
        let calls = server.requests
        #expect(calls.map(\.url.path) == ["/v1/auth/exchange", "/v1/me", "/v1/rooms", "/v1/rooms/r/components", "/v1/rooms/r/ops", "/v1/rooms/r/end", "/v1/auth/logout"])
        #expect(calls.map(\.method) == ["POST", "GET", "POST", "GET", "POST", "POST", "POST"])
        #expect(calls[0].headers["Authorization"] == nil)
        #expect(calls.dropFirst().allSatisfy { $0.headers["Authorization"] == "Bearer a1" })
        #expect(calls.allSatisfy { $0.headers["Accept"] == "application/json" })
        let json = JSONDecoder()
        #expect(try json.decode([String: String].self, from: calls[0].body) == ["code": "one-time"])
        #expect(try json.decode([String: String].self, from: calls[2].body) == ["title": "會議", "aiSource": "own"])
        #expect(try json.decode([String: [CollabOp]].self, from: calls[4].body) == ["ops": [.done(id: "doc")]])
        #expect(calls[4].headers["Content-Type"] == "application/json")
    }

    @Test func refreshRotatesCredentialsAndRetryOnlyOnce() async throws {
        let server = StubServer { call in
            switch call.url.path {
            case "/v1/auth/exchange": .status(200, Self.login)
            case "/v1/auth/refresh": .status(200, #"{"accessToken":"a2","refreshToken":"r2"}"#)
            case "/v1/me" where call.headers["Authorization"] == "Bearer a2": .status(200, Self.profile)
            default: .status(401, "")
            }
        }
        let store = MemoryTokens()
        let service = store.service(using: server)
        _ = try await service.exchange(code: "code")
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

    @Test(arguments: [200, 401, 503]) func failedAuthenticationClearsStoredCredentials(refreshStatus: Int) async throws {
        let server = StubServer { call in
            switch call.url.path {
            case "/v1/auth/exchange": .status(200, Self.login)
            case "/v1/auth/refresh": .status(refreshStatus, #"{"accessToken":"a2","refreshToken":"r2"}"#)
            default: .status(401, "")
            }
        }
        let store = MemoryTokens()
        let service = store.service(using: server)
        _ = try await service.exchange(code: "code")
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
        _ = try await storage.service(using: original).exchange(code: "code")
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
        _ = try await service.exchange(code: "code")
        await #expect(throws: CollabError.quotaExceeded(used: 10, limit: 10)) { try await service.createRoom(title: "A") }
        await #expect(throws: CollabError.roomEnded) { try await service.sendOps([.done(id: "doc")], to: "r") }
        await #expect(throws: CollabError.server(status: 403)) { try await service.endRoom("r") }
        await #expect(throws: CollabError.unreachable) { try await service.me() }
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
