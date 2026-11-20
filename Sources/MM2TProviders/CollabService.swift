import Foundation
import MM2TCore

public enum CollabError: Error, Equatable, Sendable {
    case notSignedIn
    case quotaExceeded(used: Int, limit: Int)
    case roomEnded
    case unreachable
    case server(status: Int)
}

public enum CollabLoginProvider: String, Sendable { case google, apple }

public struct CollabUser: Codable, Equatable, Sendable {
    public let id: String
    public let email: String
    public let name: String
}

public struct CollabProfile: Decodable, Sendable {
    public struct Quota: Decodable, Sendable {
        public let used: Int
        public let limit: Int
        public let period: String
    }
    public let user: CollabUser
    public let quota: Quota
}

public struct CollabRoom: Decodable, Equatable, Sendable {
    public let roomId: String
    public let shareUrl: URL
    public let hostUrl: URL
}

public struct CollabRoomComponents: Decodable, Sendable {
    public enum Status: String, Decodable, Sendable { case live, ended }
    public let status: Status
    public let components: [CollabComponent]
}

public actor CollabService {
    private struct Tokens: Codable, Equatable, Sendable {
        let accessToken: String
        let refreshToken: String
    }

    private struct StoredLogin: Codable {
        let apiURL: URL
        let tokens: Tokens
    }

    private struct Login: Decodable, Sendable {
        let accessToken: String
        let refreshToken: String
        let user: CollabUser
        var tokens: Tokens { Tokens(accessToken: accessToken, refreshToken: refreshToken) }
    }

    private struct Failure: Decodable {
        let error: String
        let used: Int?
        let limit: Int?
    }

    private struct Request: Sendable {
        let path: [String]
        let method: String
        let body: Data?

        init(_ path: String...) { self.init(path: path, method: "GET", body: nil) }
        init(post path: [String]) { self.init(path: path, method: "POST", body: nil) }
        init(post path: [String], body: some Encodable) throws {
            self.init(path: path, method: "POST", body: try JSONEncoder().encode(body))
        }
        private init(path: [String], method: String, body: Data?) {
            self.path = path
            self.method = method
            self.body = body
        }
    }

    private let baseURL: URL
    private let session: URLSession
    private let load: @Sendable () throws -> Secret?
    private let save: @Sendable (Secret) throws -> Void
    private var didLoad = false
    private var tokens: Tokens?
    private var generation = 0
    private var refreshing: Task<Tokens, any Error>?
    private var observers: [UUID: AsyncStream<Bool>.Continuation] = [:]

    public init(baseURL: URL, session: URLSession = .shared,
                load: @escaping @Sendable () throws -> Secret?, save: @escaping @Sendable (Secret) throws -> Void) {
        self.baseURL = baseURL
        self.session = session
        self.load = load
        self.save = save
    }

    public nonisolated func authStartURL(_ provider: CollabLoginProvider) -> URL {
        url(["auth", provider.rawValue, "start"]).appending(queryItems: [URLQueryItem(name: "redirect", value: "mm2t://auth")])
    }

    public func signInChanges() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield((try? currentTokens()) != nil)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    public func exchange(code: String) async throws -> CollabUser {
        let version = generation
        let request = try Request(post: ["auth", "exchange"], body: ["code": code])
        let login = try await decode(Login.self, from: request)
        try Task.checkCancellation()
        guard version == generation else { throw CollabError.notSignedIn }
        try store(login.tokens)
        generation += 1
        refreshing?.cancel()
        refreshing = nil
        return login.user
    }

    public func refresh() async throws {
        _ = try await renew(after: currentTokens(), generation: generation)
    }

    public func logout() async throws {
        _ = try currentTokens()
        let version = generation
        do { _ = try await authorized(Request(post: ["auth", "logout"])) }
        catch {
            if version == generation { try invalidate() }
            throw error
        }
        if version == generation { try invalidate() }
    }

    public func me() async throws -> CollabProfile {
        try parse(CollabProfile.self, from: await authorized(Request("me")))
    }

    public func createRoom(title: String) async throws -> CollabRoom {
        let request = try Request(post: ["rooms"], body: ["title": title, "aiSource": "own"])
        return try parse(CollabRoom.self, from: await authorized(request))
    }

    public func endRoom(_ id: String) async throws {
        _ = try await authorized(Request(post: ["rooms", id, "end"]))
    }

    public func components(in id: String) async throws -> CollabRoomComponents {
        try parse(CollabRoomComponents.self, from: await authorized(Request("rooms", id, "components")))
    }

    public func sendOps(_ ops: [CollabOp], to id: String) async throws {
        let request = try Request(post: ["rooms", id, "ops"], body: ["ops": ops])
        guard ops.count <= 200, (request.body?.count ?? 0) <= 256_000 else { throw CollabError.server(status: 400) }
        _ = try await authorized(request)
    }

    private func currentTokens() throws -> Tokens {
        if !didLoad {
            if let secret = try load() {
                let stored = try? JSONDecoder().decode(StoredLogin.self, from: Data(secret.revealed.utf8))
                if stored?.apiURL == baseURL { tokens = stored?.tokens }
            }
            didLoad = true
        }
        guard let tokens else { throw CollabError.notSignedIn }
        return tokens
    }

    private func store(_ tokens: Tokens) throws {
        let stored = StoredLogin(apiURL: baseURL, tokens: tokens)
        try save(Secret(String(decoding: JSONEncoder().encode(stored), as: UTF8.self)))
        self.tokens = tokens
        didLoad = true
        for observer in observers.values { observer.yield(true) }
    }

    private func invalidate() throws {
        generation += 1
        refreshing?.cancel()
        refreshing = nil
        tokens = nil
        didLoad = true
        for observer in observers.values { observer.yield(false) }
        try save(Secret(""))
    }

    private func renew(after previous: Tokens, generation version: Int) async throws -> Tokens {
        guard version == generation else { throw CollabError.notSignedIn }
        let current = try currentTokens()
        if current != previous { return current }
        if let refreshing { return try await refreshing.value }
        let task = Task {
            defer { if version == generation { refreshing = nil } }
            do {
                let request = try Request(post: ["auth", "refresh"], body: ["refreshToken": current.refreshToken])
                let replacement = try await decode(Tokens.self, from: request)
                guard version == generation else { throw CollabError.notSignedIn }
                try store(replacement)
                return replacement
            } catch {
                if version == generation { try? invalidate() }
                throw CollabError.notSignedIn
            }
        }
        refreshing = task
        return try await task.value
    }

    private func authorized(_ request: Request) async throws -> (Data, Int) {
        let original = try currentTokens()
        let version = generation
        do { return try await send(request, bearer: original.accessToken) }
        catch CollabError.notSignedIn {
            try Task.checkCancellation()
            let replacement = try await renew(after: original, generation: version)
            try Task.checkCancellation()
            do { return try await send(request, bearer: replacement.accessToken) }
            catch CollabError.notSignedIn {
                if version == generation, tokens == replacement { try? invalidate() }
                throw CollabError.notSignedIn
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from request: Request) async throws -> T {
        try parse(type, from: await send(request))
    }

    private func parse<T: Decodable>(_ type: T.Type, from response: (Data, Int)) throws -> T {
        do { return try JSONDecoder().decode(type, from: response.0) }
        catch { throw CollabError.server(status: response.1) }
    }

    private nonisolated func url(_ path: [String]) -> URL {
        path.reduce(baseURL.appending(component: "v1")) { $0.appending(component: $1) }
    }

    private func send(_ request: Request, bearer: String? = nil) async throws -> (Data, Int) {
        try Task.checkCancellation()
        var call = URLRequest(url: url(request.path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        call.httpMethod = request.method
        call.httpBody = request.body
        call.setValue("application/json", forHTTPHeaderField: "Accept")
        if request.body != nil { call.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let bearer { call.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let result: (Data, URLResponse)
        do { result = try await session.data(for: call) }
        catch {
            try Task.checkCancellation()
            throw CollabError.unreachable
        }
        guard let response = result.1 as? HTTPURLResponse else { throw CollabError.unreachable }
        let status = response.statusCode
        guard !(200..<300).contains(status) else { return (result.0, status) }
        let failure = try? JSONDecoder().decode(Failure.self, from: result.0)
        if status == 401 { throw CollabError.notSignedIn }
        if status == 429, failure?.error == "quota_exceeded", let used = failure?.used, let limit = failure?.limit {
            throw CollabError.quotaExceeded(used: used, limit: limit)
        }
        if failure?.error == "room_ended" { throw CollabError.roomEnded }
        throw CollabError.server(status: status)
    }
}
