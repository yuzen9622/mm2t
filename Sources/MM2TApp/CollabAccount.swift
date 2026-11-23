import Foundation
import MM2TCore
import MM2TProviders
import Observation
import OSLog

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
    private static let logger = Logger(subsystem: "dev.mm2t.app", category: "Collaboration")
    public private(set) var user: CollabUser? {
        didSet {
            if user == nil { quota = nil }
            if user != oldValue { onUserChanged?() }
        }
    }
    public private(set) var quota: CollabProfile.Quota?
    public private(set) var busy = false
    public private(set) var error: CollabError?
    private(set) var signingOut = false
    let service: CollabService
    private let pendingEnds: CollabPendingEnds
    let configuration: CollabConfiguration
    @ObservationIgnored var onUserChanged: (() -> Void)?
    @ObservationIgnored var beforeSignOut: (() async -> Void)?
    @ObservationIgnored private var profileSession = UUID()
    @ObservationIgnored private var profileRefresh: (session: UUID, task: Task<Void, Error>)?
    @ObservationIgnored private var monitoring: Task<Void, Never>?
    @ObservationIgnored private var replaying: Task<Void, Never>?
    @ObservationIgnored private var roomEndPreparations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var roomEndWrites: [CollabPendingEnds.Room: Task<Void, Never>] = [:]

    init(configuration: CollabConfiguration, credentials: any CredentialStoring, pendingEndsFile: URL,
         session: URLSession = .shared, endRetrySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         pendingEndsWrite: @escaping @Sendable (Data, URL) throws -> Void = CollabPendingEnds.writeAtomically) {
        self.configuration = configuration
        self.pendingEnds = CollabPendingEnds(file: pendingEndsFile, sleep: endRetrySleep, write: pendingEndsWrite)
        self.service = CollabService(baseURL: configuration.apiURL, session: session,
            load: { try credentials.read(.collabAccount) }, save: { try credentials.save($0, for: .collabAccount) })
    }

    deinit { monitoring?.cancel(); replaying?.cancel() }

    func observeSignIn() {
        guard monitoring == nil else { return }
        monitoring = Task { [weak self, service] in
            for await signedIn in await service.signInChanges() {
                guard let self else { return }
                let session = profileSession
                if !signedIn, !(await service.isAuthenticated), session == profileSession {
                    profileSession = UUID()
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
        do {
            let profile = try await service.me()
            quota = profile.quota
            didSignIn(profile.user)
        }
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
        let verified = try await service.exchange(code: code, codeVerifier: verifier)
        quota = nil
        didSignIn(verified)
        try? await loadProfile(for: profileSession)
    }

    public func refreshProfile() async {
        guard !signingOut else { return }
        let session = profileSession
        do {
            try await loadProfile(for: session)
        } catch CollabError.notSignedIn where session == profileSession && !Task.isCancelled {
            user = nil
        } catch {}
    }

    private func loadProfile(for session: UUID) async throws {
        if let refresh = profileRefresh, refresh.session == session {
            return try await refresh.task.value
        }
        let task = Task {
            defer { if profileRefresh?.session == session { profileRefresh = nil } }
            let profile = try await service.me()
            guard session == profileSession, !Task.isCancelled else { return }
            quota = profile.quota
            user = profile.user
        }
        profileRefresh = (session, task)
        try await task.value
    }

    private func didSignIn(_ verified: CollabUser) {
        profileSession = UUID()
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

    private var roomEndWrite: Task<Void, Never>? { roomEndPreparations.values.first ?? roomEndWrites.values.first }

    public var hasPendingRoomEndWrites: Bool { roomEndWrite != nil || pendingEnds.hasUnpersistedClosures }

    public func waitForRoomEndWrites() async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        let (completion, signal) = AsyncStream<Void>.makeStream()
        let preparation = Task { [weak self] in
            defer { signal.finish() }
            while !Task.isCancelled, clock.now < deadline, let write = self?.roomEndWrite { await write.value }
            await self?.retryRoomEndWrites(until: deadline, clock: clock)
            while !Task.isCancelled, clock.now < deadline, let write = self?.roomEndWrite { await write.value }
        }
        let timeout = Task {
            try? await clock.sleep(until: deadline)
            signal.finish()
        }
        defer { preparation.cancel(); timeout.cancel() }
        for await _ in completion {}

        let ids = pendingEnds.unpersistedRoomIDs.union(roomEndWrites.keys.map(\.id)).sorted()
        if !ids.isEmpty || !roomEndPreparations.isEmpty {
            error = .pendingEndPersistence
            Self.logger.error("Quitting with unsaved collaboration room closures: \(ids.joined(separator: ", "), privacy: .private); pending preparations: \(self.roomEndPreparations.count)")
        }
    }

    private func retryRoomEndWrites(until deadline: ContinuousClock.Instant, clock: ContinuousClock) async {
        guard pendingEnds.hasUnpersistedClosures else { return }
        for delay in [Duration.zero, .milliseconds(100), .milliseconds(250)] {
            do {
                try await Task.sleep(for: delay)
                guard clock.now < deadline else { return }
                try await pendingEnds.retryUnpersistedClosures()
                return
            } catch where Task.isCancelled { return }
            catch { continue }
        }
    }

    func prepareRoomEnd(_ prepare: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task {
            defer { roomEndPreparations.removeValue(forKey: id) }
            await prepare()
        }
        roomEndPreparations[id] = task
        return task
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
        profileSession = UUID()
        replaying?.cancel()
        defer { user = nil; signingOut = false; busy = false }
        await beforeSignOut?()
        do { try await service.logout() }
        catch CollabError.notSignedIn {}
        catch { self.error = error as? CollabError ?? .unreachable }
    }
}
