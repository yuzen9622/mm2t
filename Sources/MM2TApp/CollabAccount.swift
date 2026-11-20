import Foundation
import MM2TCore
import MM2TProviders
import Observation

public struct CollabConfiguration: Sendable {
    let apiURL: URL
    let webURL: URL

    static func live(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> Self? {
        func read(_ key: String, override: String) -> URL? {
            var value = bundle.object(forInfoDictionaryKey: key) as? String ?? ""
            #if DEBUG
            if let override = environment[override] { value = override }
            #endif
            guard let url = URL(string: value), url.host != nil, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil else { return nil }
            if url.scheme == "https" { return url }
            #if DEBUG
            if url.scheme == "http" { return url }
            #endif
            return nil
        }
        guard let api = read("MM2TCollabAPIURL", override: "MM2T_COLLAB_API_URL"),
              let web = read("MM2TCollabWebURL", override: "MM2T_COLLAB_WEB_URL") else { return nil }
        return Self(apiURL: api, webURL: web)
    }

    func accepts(_ url: URL) -> Bool {
        url.scheme == webURL.scheme && url.host == webURL.host && url.port == webURL.port && url.user == nil && url.password == nil
    }
}

@MainActor @Observable
public final class CollabAccount {
    public private(set) var user: CollabUser? { didSet { if user != oldValue { onUserChanged?() } } }
    public private(set) var busy = false
    public private(set) var error: CollabError?
    private(set) var signingOut = false
    let service: CollabService
    private let pendingEnds: CollabPendingEnds
    let configuration: CollabConfiguration
    @ObservationIgnored var onUserChanged: (() -> Void)?
    @ObservationIgnored var beforeSignOut: (() async -> Void)?
    @ObservationIgnored private var monitoring: Task<Void, Never>?
    @ObservationIgnored private var replaying: Task<Void, Never>?
    @ObservationIgnored private var roomEndWrites: [CollabPendingEnds.Room: Task<Void, Never>] = [:]

    init(configuration: CollabConfiguration, credentials: any CredentialStoring, pendingEndsFile: URL,
         session: URLSession = .shared, endRetrySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.configuration = configuration
        self.pendingEnds = CollabPendingEnds(file: pendingEndsFile, sleep: endRetrySleep)
        self.service = CollabService(baseURL: configuration.apiURL, session: session,
            load: { try credentials.read(.collabAccount) }, save: { try credentials.save($0, for: .collabAccount) })
    }

    deinit { monitoring?.cancel(); replaying?.cancel() }

    func observeSignIn() {
        guard monitoring == nil else { return }
        monitoring = Task { [weak self, service] in
            for await signedIn in await service.signInChanges() {
                guard let self else { return }
                if !signedIn, !(await service.isAuthenticated) {
                    replaying?.cancel()
                    user = nil
                } else if user == nil, !busy {
                    await restore()
                } else if !signingOut, let current = await service.signedInUser, current.id == user?.id {
                    user = current
                }
            }
        }
    }

    private func restore() async {
        busy = true
        error = nil
        defer { busy = false }
        do { didSignIn(try await service.me().user) }
        catch CollabError.notSignedIn { user = nil }
        catch { self.error = error as? CollabError ?? .unreachable }
    }

    public func signIn(_ provider: CollabLoginProvider) async {
        await signIn(provider) { try await WebAuthentication.authorize($0, callbackScheme: "mm2t") }
    }

    func signIn(_ provider: CollabLoginProvider, authorize: (URL) async throws -> URL) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let verifier = try CollabPKCE.generateVerifier()
            let url = service.authStartURL(provider, codeChallenge: CollabPKCE.challenge(for: verifier))
            let callback = try await authorize(url)
            try Task.checkCancellation()
            let codes = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "code" }
            guard callback.scheme == "mm2t", callback.host == "auth", codes?.count == 1, let code = codes?.first?.value, !code.isEmpty else {
                throw CollabError.notSignedIn
            }
            try await completeSignIn(code: code, verifier: verifier)
        } catch CalendarError.cancelled {
        } catch is CancellationError {
        } catch {
            self.error = error as? CollabError ?? .unreachable
        }
    }

    func completeSignIn(code: String, verifier: String) async throws {
        didSignIn(try await service.exchange(code: code, codeVerifier: verifier))
    }

    private func didSignIn(_ verified: CollabUser) {
        user = verified
        let previous = replaying
        previous?.cancel()
        replaying = Task { [pendingEnds, configuration, service] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await pendingEnds.replay(apiURL: configuration.apiURL, owner: verified.id, service: service)
        }
    }

    func waitForPendingEnds() async { await replaying?.value }

    public var hasPendingRoomEndWrites: Bool { !roomEndWrites.isEmpty }

    public func waitForRoomEndWrites() async {
        while let write = roomEndWrites.values.first { await write.value }
    }

    func recordRoomEnd(_ room: CollabRoom, owner: String) -> Task<Void, Never> {
        let ending = CollabPendingEnds.Room(apiURL: configuration.apiURL, owner: owner, id: room.roomId)
        if let write = roomEndWrites[ending] { return write }
        pendingEnds.reserve(ending)
        let write = Task {
            defer { roomEndWrites.removeValue(forKey: ending) }
            do { try await pendingEnds.record(ending) }
            catch { self.error = .pendingEndPersistence }
        }
        roomEndWrites[ending] = write
        return write
    }

    func closeRoom(_ room: CollabRoom, owner: String) async {
        do {
            try await pendingEnds.close(.init(apiURL: configuration.apiURL, owner: owner, id: room.roomId), service: service)
        } catch CollabError.notSignedIn {
        } catch {
            if self.error != .pendingEndPersistence { self.error = error as? CollabError ?? .unreachable }
        }
    }

    public func signOut() async {
        guard !busy else { return }
        busy = true
        error = nil
        signingOut = true
        replaying?.cancel()
        defer { user = nil; signingOut = false; busy = false }
        await beforeSignOut?()
        do { try await service.logout() }
        catch CollabError.notSignedIn {}
        catch { self.error = error as? CollabError ?? .unreachable }
    }
}
