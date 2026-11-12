import CryptoKit
import Foundation
import MM2TCore
import MM2TProviders
import Network

// Google Calendar and Outlook (Microsoft 365) as calendar sources: OAuth 2.0 for installed apps
// (authorization code with PKCE and a loopback redirect), then each service's own events API.
// Google Desktop clients may require a bundled client secret for protocol compatibility;
// it is not proof of app identity and never replaces PKCE or state validation.
// User refresh tokens are kept in the Keychain; access tokens live in memory.

// MARK: OAuth

// Only allowlisted categories leave the OAuth boundary. Never retain response bodies,
// error descriptions, authorization codes, callback URLs, or credentials in diagnostics.
public struct GoogleOAuthFailure: Error, Hashable, Sendable {
    public enum Reason: String, Sendable {
        case clientSecretRequired = "client_secret_required"
        case invalidClient = "invalid_client"
        case invalidRequest = "invalid_request"
        case invalidGrant = "invalid_grant"
        case unauthorizedClient = "unauthorized_client"
        case invalidScope = "invalid_scope"
        case accessDenied = "access_denied"
        case unsupportedGrantType = "unsupported_grant_type"
        case invalidCallback = "invalid_callback"
        case invalidResponse = "invalid_response"
        case missingRefreshToken = "missing_refresh_token"
        case credentialStorage = "credential_storage_failed"
        case unknown = "oauth_error"
    }

    public let reason: Reason
    public let httpStatus: Int?

    init(_ reason: Reason, httpStatus: Int? = nil) {
        self.reason = reason
        self.httpStatus = httpStatus
    }

    public var diagnostic: String {
        httpStatus.map { "HTTP \($0) / \(reason.rawValue)" } ?? reason.rawValue
    }

    static func response(status: Int, data: Data) -> GoogleOAuthFailure {
        let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = fields?["error"] as? String
        let description = (fields?["error_description"] as? String ?? "").lowercased()
        if error == "invalid_request", description.contains("client_secret"), description.contains("missing") {
            return GoogleOAuthFailure(.clientSecretRequired, httpStatus: status)
        }
        return GoogleOAuthFailure(reason(for: error), httpStatus: status)
    }

    static func authorization(error: String) -> GoogleOAuthFailure {
        GoogleOAuthFailure(reason(for: error))
    }

    private static func reason(for error: String?) -> Reason {
        let allowed: [String: Reason] = [
            "invalid_client": .invalidClient, "invalid_request": .invalidRequest,
            "invalid_grant": .invalidGrant, "unauthorized_client": .unauthorizedClient,
            "invalid_scope": .invalidScope, "access_denied": .accessDenied,
            "unsupported_grant_type": .unsupportedGrantType,
        ]
        return error.flatMap { allowed[$0] } ?? .unknown
    }
}


public enum OAuthClientID {
    /// The Info.plist value, or nil while it is still the shipped placeholder or an unset build setting.
    public static func resolve(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !text.hasPrefix("REPLACE_"), !text.contains("$(") else { return nil }
        return text
    }
}

/// A Desktop client compatibility value, not a confidential app identity credential.
/// Loaded from the locally prepared build plist; never included in diagnostics.
public enum GoogleOAuthClientSecret {
    public static func resolve(_ value: Any?) -> Secret? {
        OAuthClientID.resolve(value).map { Secret($0) }
    }
}

/// What differs between the two services' sign-in.
struct OAuthService: Sendable {
    let kind: CalendarSourceKind
    let authorizeURL: URL
    let tokenURL: URL
    let scope: String
    /// Google wants the loopback IP; Microsoft's portal only takes `http://localhost` (any port matches).
    let redirectHost: String
    let extraAuthorizeItems: [URLQueryItem]
    /// Microsoft accepts the scope on token requests and uses it to pick the resource.
    let scopeOnTokenRequests: Bool
    let credential: Credential

    static let google = OAuthService(
        kind: .google,
        authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
        scope: "https://www.googleapis.com/auth/calendar.readonly",
        redirectHost: "127.0.0.1", extraAuthorizeItems: [], scopeOnTokenRequests: false,
        credential: .googleCalendarRefreshToken)

    static let microsoft = OAuthService(
        kind: .microsoft,
        authorizeURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
        tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
        scope: "Calendars.Read offline_access",
        redirectHost: "localhost", extraAuthorizeItems: [URLQueryItem(name: "response_mode", value: "query")],
        scopeOnTokenRequests: true, credential: .microsoftCalendarRefreshToken)

    func authorizationURL(clientID: String, redirect: String, state: String, challenge: String) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ] + extraAuthorizeItems
        return components.url!
    }

    func tokenRequest(clientID: String, clientSecret: Secret? = nil, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = [("client_id", clientID)] + fields
        if kind == .google, let clientSecret, !clientSecret.isEmpty {
            all.append(("client_secret", clientSecret.revealed))
        }
        if scopeOnTokenRequests { all.append(("scope", scope)) }
        request.httpBody = Data(all.map { "\($0)=\(Self.formEncode($1))" }.joined(separator: "&").utf8)
        return request
    }

    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? value
    }
}

enum PKCE {
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return Data(bytes).base64URL
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct AccessToken: Sendable {
    let value: String
    let expires: Date

    /// Refreshes a minute early, so a token never expires between the check and the request.
    static func needsRefresh(_ token: AccessToken?, now: Date) -> Bool {
        guard let token else { return true }
        return token.expires.timeIntervalSince(now) < 60
    }
}

struct TokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Double?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

// MARK: Events APIs

/// Calendar API v3 `events.list` on the user's primary calendar.
enum GoogleCalendarAPI {
    static func request(from start: Date, to end: Date, pageToken: String?, token: String) -> URLRequest {
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "timeMin", value: rfc3339(start)),
            URLQueryItem(name: "timeMax", value: rfc3339(end)),
            URLQueryItem(name: "maxResults", value: "250"),
        ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func page(_ data: Data) throws -> (events: [CalendarEvent], next: String?) {
        let list = try JSONDecoder().decode(List.self, from: data)
        let events = (list.items ?? []).compactMap { item -> CalendarEvent? in
            guard item.status != "cancelled", item.eventType != "workingLocation",
                  item.attendees?.first(where: { $0.isSelf == true })?.responseStatus != "declined",
                  let start = item.start, let end = item.end else { return nil }
            let isAllDay = start.dateTime == nil
            guard let from = isAllDay ? start.date.flatMap(localDay) : start.dateTime.flatMap(internetDate),
                  let to = isAllDay ? end.date.flatMap(localDay) : end.dateTime.flatMap(internetDate) else { return nil }
            let video = item.conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri
            return CalendarEvent(
                id: "google:\(item.id)", title: item.summary ?? "", start: from, end: to, isAllDay: isAllDay,
                calendar: "", link: (item.hangoutLink ?? video).flatMap(URL.init(string:))
                    ?? MeetingLink.find(in: [item.location, item.description].compactMap { $0 }),
                source: .google, uid: item.iCalUID)
        }
        return (events, list.nextPageToken)
    }

    private struct List: Decodable {
        let items: [Item]?
        let nextPageToken: String?
    }

    private struct Item: Decodable {
        let id: String
        let status: String?
        let summary: String?
        let description: String?
        let location: String?
        let iCalUID: String?
        let start: When?
        let end: When?
        let hangoutLink: String?
        let conferenceData: Conference?
        let attendees: [Attendee]?
        let eventType: String?
    }

    private struct When: Decodable {
        let date: String?
        let dateTime: String?
    }

    private struct Conference: Decodable {
        let entryPoints: [EntryPoint]?
    }

    private struct EntryPoint: Decodable {
        let entryPointType: String?
        let uri: String?
    }

    private struct Attendee: Decodable {
        let isSelf: Bool?
        let responseStatus: String?
        enum CodingKeys: String, CodingKey {
            case isSelf = "self"
            case responseStatus
        }
    }
}

/// Microsoft Graph `/me/calendarView` on the user's default calendar, times asked for in UTC.
enum GraphCalendarAPI {
    static func firstURL(from start: Date, to end: Date) -> URL {
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/calendarView")!
        components.queryItems = [
            URLQueryItem(name: "startDateTime", value: rfc3339(start)),
            URLQueryItem(name: "endDateTime", value: rfc3339(end)),
            URLQueryItem(name: "$top", value: "100"),
            URLQueryItem(name: "$select", value: "id,subject,start,end,isAllDay,isCancelled,onlineMeeting,location,bodyPreview,iCalUId,responseStatus"),
        ]
        return components.url!
    }

    static func request(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")
        return request
    }

    static func page(_ data: Data) throws -> (events: [CalendarEvent], next: URL?) {
        let list = try JSONDecoder().decode(List.self, from: data)
        let events = list.value.compactMap { item -> CalendarEvent? in
            guard item.isCancelled != true, item.responseStatus?.response != "declined",
                  let start = item.start, let end = item.end else { return nil }
            let isAllDay = item.isAllDay == true
            // An all-day event is midnight to midnight on its own dates, whatever zone the times came in.
            guard let from = isAllDay ? localDay(String(start.dateTime.prefix(10))) : utcDate(start.dateTime),
                  let to = isAllDay ? localDay(String(end.dateTime.prefix(10))) : utcDate(end.dateTime) else { return nil }
            return CalendarEvent(
                id: "microsoft:\(item.id)", title: item.subject ?? "", start: from, end: to, isAllDay: isAllDay,
                calendar: "", link: item.onlineMeeting?.joinUrl.flatMap(URL.init(string:))
                    ?? MeetingLink.find(in: [item.location?.displayName, item.bodyPreview].compactMap { $0 }),
                source: .microsoft, uid: item.iCalUId)
        }
        return (events, list.nextLink.flatMap(URL.init(string:)))
    }

    /// Graph writes `2026-11-11T02:00:00.0000000` with the zone given apart; it is UTC here.
    private static func utcDate(_ text: String) -> Date? {
        internetDate(String(text.prefix(19)) + "Z")
    }

    private struct List: Decodable {
        let value: [Item]
        let nextLink: String?
        enum CodingKeys: String, CodingKey {
            case value
            case nextLink = "@odata.nextLink"
        }
    }

    private struct Item: Decodable {
        let id: String
        let subject: String?
        let start: When?
        let end: When?
        let isAllDay: Bool?
        let isCancelled: Bool?
        let onlineMeeting: Online?
        let location: Location?
        let bodyPreview: String?
        let iCalUId: String?
        let responseStatus: Response?
    }

    private struct When: Decodable {
        let dateTime: String
    }

    private struct Online: Decodable {
        let joinUrl: String?
    }

    private struct Location: Decodable {
        let displayName: String?
    }

    private struct Response: Decodable {
        let response: String?
    }
}

private func rfc3339(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func internetDate(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
}

/// `yyyy-MM-dd` as midnight on this Mac's calendar.
private func localDay(_ text: String) -> Date? {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
}

// MARK: Source

/// Google Calendar or Outlook, signed in through the browser.
public actor OnlineCalendar: CalendarSource {
    public nonisolated let kind: CalendarSourceKind
    private let service: OAuthService
    private let clientID: String?
    private let clientSecret: Secret?
    private let credentials: any CredentialStoring
    private let signedInPage: String
    private let openBrowser: @Sendable (URL) async -> Void
    private let session: URLSession
    private var access: AccessToken?

    /// `clientID` nil (the Info.plist placeholder) makes the source unavailable in this build.
    /// `signedInPage` is the text the browser shows once sign-in hands back to the app.
    public static func google(clientID: String?, clientSecret: Secret? = nil, credentials: any CredentialStoring, signedInPage: String,
                              openBrowser: @escaping @Sendable (URL) async -> Void) -> OnlineCalendar {
        OnlineCalendar(service: .google, clientID: clientID, clientSecret: clientSecret, credentials: credentials, signedInPage: signedInPage, openBrowser: openBrowser)
    }

    public static func microsoft(clientID: String?, credentials: any CredentialStoring, signedInPage: String,
                                 openBrowser: @escaping @Sendable (URL) async -> Void) -> OnlineCalendar {
        OnlineCalendar(service: .microsoft, clientID: clientID, credentials: credentials, signedInPage: signedInPage, openBrowser: openBrowser)
    }

    init(service: OAuthService, clientID: String?, clientSecret: Secret? = nil, credentials: any CredentialStoring, signedInPage: String,
         openBrowser: @escaping @Sendable (URL) async -> Void, session: URLSession = .shared) {
        kind = service.kind
        self.service = service
        self.clientID = clientID
        self.clientSecret = service.kind == .google ? clientSecret : nil
        self.credentials = credentials
        self.signedInPage = signedInPage
        self.openBrowser = openBrowser
        self.session = session
    }

    public func status() -> CalendarConnection {
        guard clientID != nil else { return .unavailable }
        return refreshToken == nil ? .disconnected : .connected
    }

    public func connect() async throws {
        guard let clientID else { throw CalendarError.unavailable }
        let redirect = try LoopbackRedirect(page: signedInPage)
        defer { redirect.cancel() }
        let port = try await redirect.start()
        let redirectURI = "http://\(service.redirectHost):\(port)"
        let verifier = PKCE.verifier()
        let state = PKCE.verifier()
        await openBrowser(service.authorizationURL(clientID: clientID, redirect: redirectURI, state: state,
                                                   challenge: PKCE.challenge(for: verifier)))
        let items = try await withThrowingTaskGroup(of: [URLQueryItem].self) { group in
            group.addTask { try await redirect.callback() }
            group.addTask {
                try await Task.sleep(for: .seconds(300))
                throw CalendarError.cancelled
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if kind == .google {
            // An error or cancellation is also an authorization response: validate its
            // state before accepting it, just as we do before exchanging a code.
            guard value("state") == state else { throw GoogleOAuthFailure(.invalidCallback) }
            if let error = value("error") {
                if error == "access_denied" { throw CalendarError.cancelled }
                throw GoogleOAuthFailure.authorization(error: error)
            }
        }
        if value("error") == "access_denied" { throw CalendarError.cancelled }
        guard value("state") == state, let code = value("code"), kind != .google || !code.isEmpty else {
            if kind == .google { throw GoogleOAuthFailure(.invalidCallback) }
            throw CalendarError.signInFailed
        }
        let response = try await token(service.tokenRequest(clientID: clientID, clientSecret: clientSecret, [
            ("grant_type", "authorization_code"), ("code", code), ("code_verifier", verifier), ("redirect_uri", redirectURI),
        ]))
        guard let refresh = response.refreshToken else {
            if kind == .google { throw GoogleOAuthFailure(.missingRefreshToken, httpStatus: 200) }
            throw CalendarError.signInFailed
        }
        if kind == .google {
            guard !refresh.isEmpty else { throw GoogleOAuthFailure(.missingRefreshToken, httpStatus: 200) }
            do { try credentials.save(Secret(refresh), for: service.credential) }
            catch { throw GoogleOAuthFailure(.credentialStorage) }
        } else {
            try? credentials.save(Secret(refresh), for: service.credential)
        }
    }

    public func disconnect() {
        access = nil
        try? credentials.save(Secret(""), for: service.credential)
    }

    public func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        guard clientID != nil, refreshToken != nil else { return [] }
        do {
            return try await fetch(from: start, to: end)
        } catch CalendarError.signedOut where access != nil {
            // A rejected access token gets one fresh one before the sign-in is given up on.
            access = nil
            do {
                return try await fetch(from: start, to: end)
            } catch CalendarError.signedOut {
                disconnect()
                throw CalendarError.signedOut
            }
        }
    }

    private var refreshToken: Secret? {
        (try? credentials.read(service.credential)).flatMap { $0?.isEmpty == false ? $0 : nil }
    }

    private func fetch(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let token = try await accessToken()
        var events: [CalendarEvent] = []
        if kind == .google {
            var pageToken: String?
            for _ in 0..<5 {
                let page = try GoogleCalendarAPI.page(try await get(GoogleCalendarAPI.request(from: start, to: end, pageToken: pageToken, token: token)))
                events += page.events
                guard let next = page.next else { break }
                pageToken = next
            }
        } else {
            var url: URL? = GraphCalendarAPI.firstURL(from: start, to: end)
            for _ in 0..<5 {
                guard let current = url else { break }
                let page = try GraphCalendarAPI.page(try await get(GraphCalendarAPI.request(current, token: token)))
                events += page.events
                url = page.next
            }
        }
        return events
    }

    private func accessToken() async throws -> String {
        if !AccessToken.needsRefresh(access, now: Date()), let access { return access.value }
        guard let clientID, let refresh = refreshToken else { throw CalendarError.signedOut }
        let response: TokenResponse
        do {
            response = try await token(service.tokenRequest(clientID: clientID, clientSecret: clientSecret, [
                ("grant_type", "refresh_token"), ("refresh_token", refresh.revealed),
            ]))
        } catch let failure as GoogleOAuthFailure where failure.reason == .invalidGrant {
            disconnect()
            throw CalendarError.signedOut
        }
        // Microsoft may hand out a new refresh token; the old one is then to be discarded.
        if let rotated = response.refreshToken { try? credentials.save(Secret(rotated), for: service.credential) }
        access = AccessToken(value: response.accessToken, expires: Date().addingTimeInterval(response.expiresIn ?? 3600))
        return response.accessToken
    }

    private func token(_ request: URLRequest) async throws -> TokenResponse {
        let (data, status) = try await send(request)
        if kind == .google {
            guard status == 200 else { throw GoogleOAuthFailure.response(status: status, data: data) }
            guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
                throw GoogleOAuthFailure(.invalidResponse, httpStatus: status)
            }
            return response
        }
        if status == 400 || status == 401 {
            // invalid_grant: the refresh token was revoked or expired; keep no dead sign-in around.
            if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String == "invalid_grant" {
                disconnect()
                throw CalendarError.signedOut
            }
            throw CalendarError.signInFailed
        }
        guard status == 200, let response = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw CalendarError.signInFailed
        }
        return response
    }

    private func get(_ request: URLRequest) async throws -> Data {
        let (data, status) = try await send(request)
        switch status {
        case 200: return data
        case 401: throw CalendarError.signedOut
        default: throw CalendarError.unreachable
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw CalendarError.unreachable
        }
    }
}

// MARK: Loopback redirect

/// A one-shot HTTP listener on the loopback interface that catches the browser coming back from
/// sign-in with `?code=…&state=…`, answers with a short page, and hands over the query.
final class LoopbackRedirect: @unchecked Sendable {
    private let listener: NWListener
    private let page: String
    private let queue = DispatchQueue(label: "app.mm2t.oauth-redirect")
    private let lock = NSLock()
    private var waiting: CheckedContinuation<[URLQueryItem], Error>?
    private var outcome: Result<[URLQueryItem], Error>?

    init(page: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        self.page = page
    }

    /// Starts listening and returns the port the system picked.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (started: CheckedContinuation<UInt16, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    once.run { started.resume(returning: self?.listener.port?.rawValue ?? 0) }
                case .failed, .cancelled:
                    once.run { started.resume(throwing: CalendarError.signInFailed) }
                    self?.finish(.failure(CalendarError.signInFailed))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    func callback() async throws -> [URLQueryItem] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(with: outcome)
                } else {
                    waiting = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
        listener.cancel()
    }

    private func finish(_ result: Result<[URLQueryItem], Error>) {
        lock.lock()
        guard outcome == nil else { return lock.unlock() }
        outcome = result
        let continuation = waiting
        waiting = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            // The request line: "GET /?code=…&state=… HTTP/1.1".
            let target = data.flatMap { String(data: $0, encoding: .utf8) }?
                .split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init)
            let items = target.flatMap { URLComponents(string: $0)?.queryItems } ?? []
            let isCallback = items.contains { $0.name == "code" || $0.name == "error" }
            let body = isCallback ? Self.html(page) : ""
            let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if isCallback { finish(.success(items)) }
        }
    }

    private static func html(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return "<!doctype html><meta charset=utf-8><title>mm2t</title>"
            + "<body style=\"font:16px -apple-system,sans-serif;display:grid;place-items:center;height:90vh;color:#1c1c1e\">"
            + "<p>\(escaped)</p></body>"
    }
}

/// Runs its closure the first time only; the listener can report ready and then fail.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
