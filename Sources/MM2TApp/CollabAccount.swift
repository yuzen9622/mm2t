import Foundation
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
    let service: CollabService
    let configuration: CollabConfiguration
    @ObservationIgnored var onUserChanged: (() -> Void)?
    @ObservationIgnored var beforeSignOut: (() async -> Void)?
    @ObservationIgnored private var monitoring: Task<Void, Never>?

    init(configuration: CollabConfiguration, credentials: any CredentialStoring, session: URLSession = .shared) {
        self.configuration = configuration
        self.service = CollabService(baseURL: configuration.apiURL, session: session,
            load: { try credentials.read(.collabAccount) }, save: { try credentials.save($0, for: .collabAccount) })
    }

    deinit { monitoring?.cancel() }

    func observeSignIn() {
        guard monitoring == nil else { return }
        monitoring = Task { [weak self, service] in
            for await signedIn in await service.signInChanges() {
                guard let self else { return }
                if !signedIn { user = nil }
                else if user == nil, !busy { await restore() }
            }
        }
    }

    private func restore() async {
        busy = true
        error = nil
        defer { busy = false }
        do { user = try await service.me().user }
        catch CollabError.notSignedIn { user = nil }
        catch { self.error = error as? CollabError ?? .unreachable }
    }

    public func signIn(_ provider: CollabLoginProvider) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let callback = try await WebAuthentication.authorize(service.authStartURL(provider), callbackScheme: "mm2t")
            let codes = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "code" }
            guard callback.scheme == "mm2t", callback.host == "auth", codes?.count == 1, let code = codes?.first?.value, !code.isEmpty else {
                throw CollabError.notSignedIn
            }
            user = try await service.exchange(code: code)
        } catch CalendarError.cancelled {
        } catch is CancellationError {
        } catch {
            self.error = error as? CollabError ?? .unreachable
        }
    }

    public func signOut() async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false; user = nil }
        await beforeSignOut?()
        do { try await service.logout() }
        catch CollabError.notSignedIn {}
        catch { self.error = error as? CollabError ?? .unreachable }
    }
}
