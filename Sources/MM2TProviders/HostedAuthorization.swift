import Foundation
import MM2TCore

/// Where hosted-plan requests get their bearer. Account access tokens last 15 minutes, so each
/// request asks for the current one, and a 401 gets one renewal and one retry.
public struct HostedAuthorization: Sendable {
    /// The token stored when the pipeline was built; fakes record it.
    public let stored: Secret
    private let current: @Sendable () async throws -> Secret
    private let renewal: @Sendable (Secret) async throws -> Secret

    public init(stored: Secret, current: @escaping @Sendable () async throws -> Secret,
                renew: @escaping @Sendable (Secret) async throws -> Secret) {
        self.stored = stored
        self.current = current
        self.renewal = renew
    }

    /// A token that is never renewed: a 401 stays a credential failure.
    public static func fixed(_ token: Secret) -> Self {
        Self(stored: token, current: { token }, renew: { _ in throw ProviderError(.mm2tPlan, .invalidCredential) })
    }

    /// Renews through the signed-in account; signing out surfaces as a rejected credential.
    public init(stored: Secret, account: CollabService) {
        self.init(stored: stored, current: {
            do { return try await account.accessToken() } catch { throw Self.signedOut(error) }
        }, renew: { rejected in
            do { return try await account.renewAccessToken(after: rejected) } catch { throw Self.signedOut(error) }
        })
    }

    private static func signedOut(_ error: any Error) -> any Error {
        error is CancellationError ? error : ProviderError(.mm2tPlan, .invalidCredential)
    }

    func token() async throws -> Secret { try await current() }

    /// Sends `make(token)`; after a 401 it renews the token and sends once more.
    func send(_ session: URLSession, _ make: (Secret) throws -> URLRequest) async throws -> HTTPResponse {
        let token = try await current()
        let response = try await session.send(make(token), for: .mm2tPlan)
        guard response.status == 401 else { return response }
        return try await session.send(make(renewal(token)), for: .mm2tPlan)
    }

    /// The streamed counterpart of `send`.
    func connect(_ session: URLSession, _ make: (Secret) throws -> URLRequest) async throws -> (URLSession.AsyncBytes, Int) {
        let token = try await current()
        let first = try await TextStreaming.connect(make(token), session: session, service: .mm2tPlan)
        guard first.1 == 401 else { return first }
        first.0.task.cancel()
        return try await TextStreaming.connect(make(renewal(token)), session: session, service: .mm2tPlan)
    }
}

/// What a hosted AI request is for (`X-MM2T-Purpose`): meeting processing draws on the budget that
/// hosted minutes earn, while questions and rewrites count as the user's own requests.
public enum HostedPurpose: String, Sendable {
    case ask, rewrite, auto
}
