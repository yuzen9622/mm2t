import Foundation
import MM2TCore
import MM2TProviders
import Testing
@testable import MM2TApp

// Token-endpoint replies are synthetic; the browser callback uses a real local listener.
private final class OAuthReplyProtocol: URLProtocol, @unchecked Sendable {
    static let header = "X-MM2T-OAuth-Test"
    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: header) != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let testCase = request.value(forHTTPHeaderField: Self.header)
        let status: Int
        let body: String
        switch testCase {
        case "configured-code", "configured-refresh", "microsoft-no-secret":
            let data: Data
            if let body = request.httpBody {
                data = body
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
                data = body
            } else {
                data = Data()
            }
            let text = String(decoding: data, as: UTF8.self)
            let fields = URLComponents(string: "?" + text)?.queryItems ?? []
            let value = { (key: String) in fields.first { $0.name == key }?.value }
            if request.url?.path == "/token" {
                #expect(request.url?.query == nil)
                #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
                #expect(request.httpMethod == "POST")
                #expect(value("client_secret") == "synthetic-only+&=%/value")
                #expect(value("grant_type") == (testCase == "configured-code" ? "authorization_code" : "refresh_token"))
                if testCase == "configured-code" { #expect(value("code_verifier")?.isEmpty == false) }
                status = 200
                body = #"{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","expires_in":3600}"#
            } else if testCase == "microsoft-no-secret" {
                #expect(request.url?.host == "login.microsoftonline.com")
                #expect(value("client_secret") == nil)
                status = 200
                body = #"{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","expires_in":3600}"#
            } else {
                #expect(request.url?.host == "www.googleapis.com")
                #expect(!(request.url?.query?.contains("client_secret") ?? false))
                #expect(value("client_secret") == nil)
                status = 200
                body = #"{"items":[]}"#
            }
        case "missing-secret":
            status = 400
            body = #"{"error":"invalid_request","error_description":"client_secret is missing. private-detail-must-not-escape"}"#
        case "invalid-grant":
            status = 400
            body = #"{"error":"invalid_grant","error_description":"private-detail-must-not-escape"}"#
        case "must-not-exchange":
            Issue.record("An invalid callback must not reach the token endpoint")
            status = 400
            body = #"{"error":"invalid_request"}"#
        case "invalid-json":
            status = 200
            body = "not json"
        case "no-refresh":
            status = 200
            body = #"{"access_token":"synthetic-access","expires_in":3600}"#
        default:
            status = 200
            body = #"{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","expires_in":3600}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct UnwritableOAuthCredentials: CredentialStoring {
    func read(_ credential: Credential) throws -> Secret? { nil }
    func save(_ secret: Secret, for credential: Credential) throws { throw CocoaError(.fileWriteNoPermission) }
}

@Suite(.timeLimit(.minutes(1))) struct GoogleOAuthSafetyTests {
    private func source(_ service: OAuthService = .google, testCase: String,
                        credentials: any CredentialStoring = MemoryCredentials(),
                        page: Box<String> = Box(""), wrongState: Bool = false,
                        missingState: Bool = false, callbackError: String? = nil,
                        callbackCode: String = "synthetic-code", clientSecret: Secret? = nil) -> OnlineCalendar {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthReplyProtocol.self]
        configuration.httpAdditionalHeaders = [OAuthReplyProtocol.header: testCase]
        return OnlineCalendar(service: service, clientID: "synthetic-client", clientSecret: clientSecret, credentials: credentials,
                              signedInPage: service.kind == .google ? "Authorization returned. Check the app." : "Microsoft connected.",
                              openBrowser: { authorization in
            let fields = URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let redirect = fields.first(where: { $0.name == "redirect_uri" })?.value,
                  let state = fields.first(where: { $0.name == "state" })?.value,
                  var callback = URLComponents(string: redirect) else {
                Issue.record("Missing synthetic authorization fields")
                return
            }
            callback.queryItems = [callbackError.map { URLQueryItem(name: "error", value: $0) }
                                   ?? URLQueryItem(name: "code", value: callbackCode)]
            if !missingState {
                callback.queryItems?.append(URLQueryItem(name: "state", value: wrongState ? "wrong" : state))
            }
            guard let url = callback.url else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                page.set(String(decoding: data, as: UTF8.self))
            } catch { Issue.record("Synthetic local callback failed") }
        }, session: URLSession(configuration: configuration))
    }

    @Test func configuredGoogleCodeAndRefreshIncludeOnlyTheSyntheticSecret() async throws {
        let secret = Secret("synthetic-only+&=%/value")
        let credentials = MemoryCredentials()
        let page = Box("")
        let code = source(testCase: "configured-code", credentials: credentials, page: page, clientSecret: secret)
        try await code.connect()
        #expect(await code.status() == .connected)
        #expect(!page.get.contains(secret.revealed))
        let refresh = source(testCase: "configured-refresh", credentials: credentials, clientSecret: secret)
        #expect(try await refresh.events(from: .distantPast, to: .distantFuture).isEmpty)
        #expect(await refresh.status() == .connected)
    }

    @Test func microsoftNeverReceivesTheGoogleSecret() async throws {
        let calendar = source(.microsoft, testCase: "microsoft-no-secret", clientSecret: Secret("synthetic-only+&=%/value"))
        try await calendar.connect()
        #expect(await calendar.status() == .connected)
    }

    @Test func googleAuthorizationKeepsPKCEAndStateWithoutASecret() {
        let url = OAuthService.google.authorizationURL(clientID: "synthetic-client", redirect: "http://127.0.0.1:5555", state: "synthetic-state", challenge: "synthetic-challenge")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "code_challenge_method", value: "S256")))
        #expect(items.contains(URLQueryItem(name: "code_challenge", value: "synthetic-challenge")))
        #expect(items.contains(URLQueryItem(name: "state", value: "synthetic-state")))
        #expect(!items.contains { $0.name == "client_secret" })
    }

    @Test func localGoogleConfigurationIsOptionalAndRedacted() {
        for value: Any? in [nil, "", " ", "REPLACE_SECRET", "$(GOOGLE_SECRET)", 42] {
            #expect(GoogleOAuthClientSecret.resolve(value) == nil)
        }
        let secret = GoogleOAuthClientSecret.resolve(" synthetic-only+&=%/value ")
        #expect(secret?.revealed == "synthetic-only+&=%/value")
        #expect(String(describing: secret) == "Optional(Secret(redacted))")
        for empty: Secret? in [nil, Secret("")] {
            let request = OAuthService.google.tokenRequest(clientID: "cid", clientSecret: empty, [("grant_type", "refresh_token")])
            #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self) == "client_id=cid&grant_type=refresh_token")
        }
        let microsoft = OAuthService.microsoft.tokenRequest(clientID: "cid", clientSecret: secret, [("grant_type", "refresh_token")])
        #expect(!String(decoding: microsoft.httpBody ?? Data(), as: UTF8.self).contains("client_secret"))
    }

    @Test func diagnosticNeverIncludesServerSuppliedValues() {
        let known = GoogleOAuthFailure.response(status: 400, data: Data(#"{"error":"invalid_client","error_description":"private-detail-must-not-escape","access_token":"synthetic-private"}"#.utf8))
        #expect(known.reason == .invalidClient)
        #expect(known.diagnostic == "HTTP 400 / invalid_client")
        let unknown = GoogleOAuthFailure.response(status: 400, data: Data(#"{"error":"private-detail-must-not-escape","error_description":"synthetic-private"}"#.utf8))
        #expect(unknown.reason == .unknown)
        #expect(unknown.diagnostic == "HTTP 400 / oauth_error")
        #expect(GoogleOAuthFailure.response(status: 502, data: Data("not json".utf8)).diagnostic == "HTTP 502 / oauth_error")
    }

    @Test func googleFailureIsSpecificAndBrowserDoesNotPromiseSuccess() async throws {
        let page = Box("")
        let calendar = source(testCase: "missing-secret", page: page)
        await #expect(throws: GoogleOAuthFailure(.clientSecretRequired, httpStatus: 400)) {
            try await calendar.connect()
        }
        #expect(await calendar.status() == .disconnected)
        #expect(page.get.contains("Authorization returned. Check the app."))
        #expect(!page.get.contains("connected"))
        #expect(!page.get.contains("synthetic-code"))
    }

    @Test func microsoftSuccessfulSignInAndPageAreUnchanged() async throws {
        let credentials = MemoryCredentials()
        let page = Box("")
        let calendar = source(.microsoft, testCase: "success", credentials: credentials, page: page)
        try await calendar.connect()
        #expect(await calendar.status() == .connected)
        #expect(page.get.contains("Microsoft connected."))
        #expect(try credentials.read(.microsoftCalendarRefreshToken)?.revealed == "synthetic-refresh")
    }

    @Test func googleSuccessfulSignInStillStoresItsRefreshToken() async throws {
        let credentials = MemoryCredentials()
        let calendar = source(testCase: "success", credentials: credentials)
        try await calendar.connect()
        #expect(await calendar.status() == .connected)
        #expect(try credentials.read(.googleCalendarRefreshToken)?.revealed == "synthetic-refresh")
    }

    @Test func googleMissingRefreshAndStorageFailureAreDistinct() async throws {
        let missing = source(testCase: "no-refresh")
        await #expect(throws: GoogleOAuthFailure(.missingRefreshToken, httpStatus: 200)) {
            try await missing.connect()
        }
        let unsaved = source(testCase: "success", credentials: UnwritableOAuthCredentials())
        await #expect(throws: GoogleOAuthFailure(.credentialStorage)) { try await unsaved.connect() }
        #expect(await unsaved.status() == .disconnected)
    }

    @Test func invalidCallbackDoesNotExchangeAuthorization() async throws {
        let calendar = source(testCase: "must-not-exchange", wrongState: true)
        await #expect(throws: GoogleOAuthFailure(.invalidCallback)) { try await calendar.connect() }
        #expect(await calendar.status() == .disconnected)
    }

    @Test func googleCancellationRequiresTheMatchingState() async throws {
        let valid = source(testCase: "must-not-exchange", callbackError: "access_denied")
        await #expect(throws: CalendarError.cancelled) { try await valid.connect() }
        #expect(await valid.status() == .disconnected)

        let wrong = source(testCase: "must-not-exchange", wrongState: true, callbackError: "access_denied")
        await #expect(throws: GoogleOAuthFailure(.invalidCallback)) { try await wrong.connect() }
        let missing = source(testCase: "must-not-exchange", missingState: true, callbackError: "access_denied")
        await #expect(throws: GoogleOAuthFailure(.invalidCallback)) { try await missing.connect() }
    }

    @Test func googleErrorCallbacksValidateStateBeforeClassifyingTheError() async throws {
        let valid = source(testCase: "must-not-exchange", callbackError: "invalid_scope")
        await #expect(throws: GoogleOAuthFailure(.invalidScope)) { try await valid.connect() }
        let wrong = source(testCase: "must-not-exchange", wrongState: true, callbackError: "invalid_scope")
        await #expect(throws: GoogleOAuthFailure(.invalidCallback)) { try await wrong.connect() }
        let missing = source(testCase: "must-not-exchange", missingState: true, callbackError: "invalid_scope")
        await #expect(throws: GoogleOAuthFailure(.invalidCallback)) { try await missing.connect() }
        let unknown = source(testCase: "must-not-exchange", callbackError: "private-detail-must-not-escape")
        await #expect(throws: GoogleOAuthFailure(.unknown)) { try await unknown.connect() }
    }

    @Test func googleCodeRequiresStateAndANonemptyCode() async throws {
        let missing = source(testCase: "must-not-exchange", missingState: true)
        await #expect(throws: GoogleOAuthFailure(.invalidCallback)) { try await missing.connect() }
        let empty = source(testCase: "must-not-exchange", callbackCode: "")
        await #expect(throws: GoogleOAuthFailure(.invalidCallback)) { try await empty.connect() }
    }

    @Test func microsoftCancellationBehaviorIsUnchanged() async throws {
        let calendar = source(.microsoft, testCase: "must-not-exchange", callbackError: "access_denied")
        await #expect(throws: CalendarError.cancelled) { try await calendar.connect() }
        let priorBehavior = source(.microsoft, testCase: "must-not-exchange", wrongState: true, callbackError: "access_denied")
        await #expect(throws: CalendarError.cancelled) { try await priorBehavior.connect() }
    }

    @Test func malformedSuccessIsReportedWithoutResponseContents() async throws {
        let calendar = source(testCase: "invalid-json")
        await #expect(throws: GoogleOAuthFailure(.invalidResponse, httpStatus: 200)) {
            try await calendar.connect()
        }
    }

    @Test func failedCodeExchangeDoesNotEraseAnExistingGoogleConnection() async throws {
        let credentials = MemoryCredentials()
        try credentials.save(Secret("existing-synthetic-refresh"), for: .googleCalendarRefreshToken)
        let calendar = source(testCase: "invalid-grant", credentials: credentials)
        await #expect(throws: GoogleOAuthFailure(.invalidGrant, httpStatus: 400)) {
            try await calendar.connect()
        }
        #expect(await calendar.status() == .connected)
        #expect(try credentials.read(.googleCalendarRefreshToken)?.revealed == "existing-synthetic-refresh")
    }

    @Test func revokedGoogleRefreshStillDisconnects() async throws {
        let credentials = MemoryCredentials()
        try credentials.save(Secret("synthetic-refresh"), for: .googleCalendarRefreshToken)
        let calendar = source(testCase: "invalid-grant", credentials: credentials)
        await #expect(throws: CalendarError.signedOut) {
            _ = try await calendar.events(from: .distantPast, to: .distantFuture)
        }
        #expect(await calendar.status() == .disconnected)
    }
}
