import Foundation
import MM2TCore
import MM2TProviders
import Testing
@testable import MM2TApp

/// A calendar source with scripted connection and events.
final class FakeCalendar: CalendarSource, @unchecked Sendable {
    let kind: CalendarSourceKind
    let connection: Box<CalendarConnection>
    let stored: Box<[CalendarEvent]>
    let failure = Box<CalendarError?>(nil)

    init(_ kind: CalendarSourceKind, _ connection: CalendarConnection, events: [CalendarEvent] = []) {
        self.kind = kind
        self.connection = Box(connection)
        stored = Box(events)
    }

    func status() async -> CalendarConnection { connection.get }
    func connect() async throws { connection.set(.connected) }
    func disconnect() async { connection.set(.disconnected) }
    func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        if let failure = failure.get { throw failure }
        return stored.get.filter { $0.end > start && $0.start < end }
    }
}

private func event(_ id: String, _ title: String, at start: Date, minutes: Double = 60, source: CalendarSourceKind,
                   link: String? = nil, uid: String? = nil, allDay: Bool = false) -> CalendarEvent {
    CalendarEvent(id: id, title: title, start: start, end: start.addingTimeInterval(minutes * 60), isAllDay: allDay,
                  calendar: "", link: link.flatMap(URL.init(string:)), source: source, uid: uid)
}

private func date(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

@Suite struct CalendarMergeTests {
    @Test func aMeetingSeenThroughTwoSourcesIsKeptOnceWithItsLink() {
        let ten = date("2026-11-11T02:00:00Z")
        let apple = [
            event("a1", "Design review", at: ten, source: .apple, link: "https://zoom.us/j/1", uid: "shared-uid"),
            event("a2", "Lunch", at: ten.addingTimeInterval(7200), source: .apple),
            event("a3", "Standup", at: ten.addingTimeInterval(-3600), source: .apple),
        ]
        let google = [
            event("g1", "Design review", at: ten, source: .google, uid: "shared-uid"),
            event("g2", " lunch ", at: ten.addingTimeInterval(7200 + 20), source: .google, link: "https://meet.google.com/x"),
            event("g3", "Other meeting", at: ten, source: .google),
        ]

        let merged = CalendarMerge.merge([apple, google])
        #expect(merged.map(\.id) == ["a3", "g1", "g3", "g2"])
        #expect(merged.first { $0.id == "g1" }?.link?.absoluteString == "https://zoom.us/j/1", "the link survives from the synced copy")
        #expect(merged.first { $0.id == "g2" }?.source == .google, "the direct copy wins over the one synced into macOS")
    }

    @Test func eventsAtDifferentTimesOrOfDifferentKindsStaySeparate() {
        let ten = date("2026-11-11T02:00:00Z")
        let merged = CalendarMerge.merge([
            [event("a", "Weekly", at: ten, source: .apple, uid: "series")],
            [event("b", "Weekly", at: ten.addingTimeInterval(7 * 86_400), source: .microsoft, uid: "series"),
             event("c", "Weekly", at: ten, source: .microsoft, allDay: true)],
        ])
        #expect(merged.count == 3)
    }
}

@Suite struct MonthGridTests {
    private func calendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func day(_ calendar: Calendar, _ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @Test func sixWeeksStartingOnTheLocalesFirstWeekday() {
        let sunday = calendar(firstWeekday: 1)
        let mid = day(sunday, 2026, 11, 18)
        let days = MonthGrid.days(around: mid, calendar: sunday)
        #expect(days.count == 42)
        #expect(days.first == day(sunday, 2026, 11, 1), "1 Nov 2026 is a Sunday")
        #expect(days.last == day(sunday, 2026, 12, 12))

        let monday = calendar(firstWeekday: 2)
        let mondayDays = MonthGrid.days(around: mid, calendar: monday)
        #expect(mondayDays.first == day(monday, 2026, 10, 26))
        #expect(mondayDays.allSatisfy { monday.component(.hour, from: $0) == 0 })
        #expect(Set(mondayDays).count == 42)
    }

    @Test func aMonthStartingOnTheFirstWeekdayHasNoLeadingDays() {
        let monday = calendar(firstWeekday: 2)
        #expect(MonthGrid.days(around: day(monday, 2027, 2, 10), calendar: monday).first == day(monday, 2027, 2, 1))
    }
}

@Suite struct CalendarAPITests {
    @Test func readsGoogleEventsWithTheirCallLinks() throws {
        let json = """
        {"nextPageToken": "page-2", "items": [
          {"id": "e1", "status": "confirmed", "summary": "Design review", "iCalUID": "e1@google.com",
           "start": {"dateTime": "2026-11-11T10:00:00+08:00"}, "end": {"dateTime": "2026-11-11T11:00:00+08:00"},
           "hangoutLink": "https://meet.google.com/abc-defg-hij"},
          {"id": "e2", "summary": "Offsite", "start": {"date": "2026-11-12"}, "end": {"date": "2026-11-14"}},
          {"id": "e3", "status": "cancelled", "summary": "Gone",
           "start": {"dateTime": "2026-11-11T12:00:00Z"}, "end": {"dateTime": "2026-11-11T13:00:00Z"}},
          {"id": "e4", "summary": "Declined", "start": {"dateTime": "2026-11-11T12:00:00Z"}, "end": {"dateTime": "2026-11-11T13:00:00Z"},
           "attendees": [{"email": "me@example.com", "self": true, "responseStatus": "declined"}]},
          {"id": "e5", "summary": "Vendor call", "start": {"dateTime": "2026-11-11T15:00:00Z"}, "end": {"dateTime": "2026-11-11T15:30:00Z"},
           "conferenceData": {"entryPoints": [{"entryPointType": "phone", "uri": "tel:000"},
                                              {"entryPointType": "video", "uri": "https://zoom.us/j/123"}]}},
          {"id": "e6", "summary": "Sync", "description": "Join: https://teams.microsoft.com/l/meetup-join/xyz",
           "start": {"dateTime": "2026-11-11T16:00:00.000Z"}, "end": {"dateTime": "2026-11-11T16:30:00Z"}},
          {"id": "e7", "eventType": "workingLocation", "summary": "Home", "start": {"date": "2026-11-11"}, "end": {"date": "2026-11-12"}}
        ]}
        """
        let page = try GoogleCalendarAPI.page(Data(json.utf8))
        #expect(page.next == "page-2")
        #expect(page.events.map(\.id) == ["google:e1", "google:e2", "google:e5", "google:e6"])

        let review = page.events[0]
        #expect(review.start == date("2026-11-11T02:00:00Z") && review.end == date("2026-11-11T03:00:00Z"))
        #expect(review.link?.absoluteString == "https://meet.google.com/abc-defg-hij")
        #expect(review.uid == "e1@google.com" && review.source == .google && !review.isAllDay)

        let offsite = page.events[1]
        #expect(offsite.isAllDay)
        #expect(offsite.start == Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12)))
        #expect(offsite.end == Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 14)), "Google's end date is exclusive")

        #expect(page.events[2].link?.absoluteString == "https://zoom.us/j/123", "the video entry point, not the phone one")
        #expect(page.events[3].link?.host() == "teams.microsoft.com", "a link only in the description is still found")
        #expect(page.events[3].start == date("2026-11-11T16:00:00Z"))
    }

    @Test func readsGraphCalendarViewEvents() throws {
        let json = """
        {"@odata.nextLink": "https://graph.microsoft.com/v1.0/me/calendarView?startDateTime=x&$skip=100", "value": [
          {"id": "AAMk1", "subject": "Budget", "isAllDay": false, "isCancelled": false, "iCalUId": "0400-budget",
           "start": {"dateTime": "2026-11-11T02:00:00.0000000", "timeZone": "UTC"},
           "end": {"dateTime": "2026-11-11T03:00:00.0000000", "timeZone": "UTC"},
           "onlineMeeting": {"joinUrl": "https://teams.microsoft.com/l/meetup-join/abc"},
           "location": {"displayName": ""}, "bodyPreview": ""},
          {"id": "AAMk2", "subject": "Holiday", "isAllDay": true, "isCancelled": false, "onlineMeeting": null,
           "start": {"dateTime": "2026-11-12T00:00:00.0000000", "timeZone": "UTC"},
           "end": {"dateTime": "2026-11-13T00:00:00.0000000", "timeZone": "UTC"}},
          {"id": "AAMk3", "subject": "Called off", "isAllDay": false, "isCancelled": true,
           "start": {"dateTime": "2026-11-11T05:00:00.0000000", "timeZone": "UTC"},
           "end": {"dateTime": "2026-11-11T06:00:00.0000000", "timeZone": "UTC"}},
          {"id": "AAMk4", "subject": "Customer", "isAllDay": false, "isCancelled": false, "onlineMeeting": null,
           "location": {"displayName": "https://us02web.zoom.us/j/999"},
           "start": {"dateTime": "2026-11-11T07:00:00.0000000", "timeZone": "UTC"},
           "end": {"dateTime": "2026-11-11T07:30:00.0000000", "timeZone": "UTC"}},
          {"id": "AAMk5", "subject": "Declined", "isAllDay": false, "responseStatus": {"response": "declined"},
           "start": {"dateTime": "2026-11-11T08:00:00.0000000", "timeZone": "UTC"},
           "end": {"dateTime": "2026-11-11T09:00:00.0000000", "timeZone": "UTC"}}
        ]}
        """
        let page = try GraphCalendarAPI.page(Data(json.utf8))
        #expect(page.next?.absoluteString.hasSuffix("$skip=100") == true)
        #expect(page.events.map(\.id) == ["microsoft:AAMk1", "microsoft:AAMk2", "microsoft:AAMk4"])
        #expect(page.events[0].start == date("2026-11-11T02:00:00Z"))
        #expect(page.events[0].link?.absoluteString == "https://teams.microsoft.com/l/meetup-join/abc")
        #expect(page.events[0].uid == "0400-budget" && page.events[0].source == .microsoft)
        #expect(page.events[1].isAllDay)
        #expect(page.events[1].start == Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12)))
        #expect(page.events[2].link?.host() == "us02web.zoom.us", "falls back to a link in the location")
    }

    @Test func requestsAskForSingleInstancesInTheRange() throws {
        let start = date("2026-10-25T16:00:00Z"), end = date("2026-12-06T16:00:00Z")
        let google = try #require(GoogleCalendarAPI.request(from: start, to: end, pageToken: "p2", token: "t").url)
        let items = URLComponents(url: google, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "singleEvents", value: "true")))
        #expect(items.contains(URLQueryItem(name: "timeMin", value: "2026-10-25T16:00:00Z")))
        #expect(items.contains(URLQueryItem(name: "timeMax", value: "2026-12-06T16:00:00Z")))
        #expect(items.contains(URLQueryItem(name: "pageToken", value: "p2")))

        let graph = GraphCalendarAPI.request(GraphCalendarAPI.firstURL(from: start, to: end), token: "t")
        #expect(graph.url?.path() == "/v1.0/me/calendarView")
        #expect(graph.value(forHTTPHeaderField: "Prefer") == "outlook.timezone=\"UTC\"")
        #expect(graph.value(forHTTPHeaderField: "Authorization") == "Bearer t")
    }
}

@Suite struct OAuthTests {
    @Test func placeholderClientIDsMeanNotAvailable() {
        #expect(OAuthClientID.resolve(nil) == nil)
        #expect(OAuthClientID.resolve("") == nil)
        #expect(OAuthClientID.resolve("  ") == nil)
        #expect(OAuthClientID.resolve("REPLACE_WITH_GOOGLE_OAUTH_CLIENT_ID") == nil)
        #expect(OAuthClientID.resolve("$(MM2T_GOOGLE_CLIENT_ID)") == nil)
        #expect(OAuthClientID.resolve(42) == nil)
        #expect(OAuthClientID.resolve(" 1234-abc.apps.googleusercontent.com ") == "1234-abc.apps.googleusercontent.com")
    }

    @Test func refreshesAMinuteBeforeExpiry() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(AccessToken.needsRefresh(nil, now: now))
        #expect(AccessToken.needsRefresh(AccessToken(value: "a", expires: now.addingTimeInterval(30)), now: now))
        #expect(AccessToken.needsRefresh(AccessToken(value: "a", expires: now.addingTimeInterval(-5)), now: now))
        #expect(!AccessToken.needsRefresh(AccessToken(value: "a", expires: now.addingTimeInterval(600)), now: now))
    }

    @Test func pkceMatchesTheRFCExample() {
        // RFC 7636, appendix B.
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = PKCE.verifier()
        #expect(verifier.count == 43 && !verifier.contains("=") && !verifier.contains("+") && !verifier.contains("/"))
    }

    @Test func authorizationAndTokenRequestsCarryPKCE() throws {
        let url = OAuthService.microsoft.authorizationURL(clientID: "cid", redirect: "http://localhost:5555", state: "s", challenge: "c")
        #expect(url.host() == "login.microsoftonline.com" && url.path() == "/common/oauth2/v2.0/authorize")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for (name, value) in [("client_id", "cid"), ("response_type", "code"), ("redirect_uri", "http://localhost:5555"),
                              ("scope", "Calendars.Read offline_access"), ("state", "s"), ("code_challenge", "c"),
                              ("code_challenge_method", "S256"), ("response_mode", "query")] {
            #expect(items.contains(URLQueryItem(name: name, value: value)), "\(name)")
        }

        let token = OAuthService.microsoft.tokenRequest(clientID: "cid", [("grant_type", "refresh_token"), ("refresh_token", "a+b/c=")])
        let body = String(decoding: try #require(token.httpBody), as: UTF8.self)
        #expect(body == "client_id=cid&grant_type=refresh_token&refresh_token=a%2Bb%2Fc%3D&scope=Calendars.Read%20offline_access")
        #expect(token.httpMethod == "POST" && token.url?.absoluteString == "https://login.microsoftonline.com/common/oauth2/v2.0/token")

        let google = OAuthService.google.tokenRequest(clientID: "cid", [("grant_type", "refresh_token")])
        #expect(String(decoding: try #require(google.httpBody), as: UTF8.self) == "client_id=cid&grant_type=refresh_token",
                "An unconfigured Google client gets no scope or client secret")
    }

    @Test func aSourceWithoutClientIDIsUnavailableAndDisconnectRemovesTheToken() async throws {
        let credentials = MemoryCredentials()
        let none = OnlineCalendar.google(clientID: nil, credentials: credentials, signedInPage: "", openBrowser: { _ in })
        #expect(await none.status() == .unavailable)
        await #expect(throws: CalendarError.unavailable) { try await none.connect() }

        let outlook = OnlineCalendar.microsoft(clientID: "cid", credentials: credentials, signedInPage: "", openBrowser: { _ in })
        #expect(await outlook.status() == .disconnected)
        #expect(try await outlook.events(from: .distantPast, to: .distantFuture).isEmpty, "no sign-in, no request")
        try credentials.save("refresh-token", for: .microsoftCalendarRefreshToken)
        #expect(await outlook.status() == .connected)
        await outlook.disconnect()
        #expect(await outlook.status() == .disconnected)
        #expect(try credentials.read(.microsoftCalendarRefreshToken) == nil)
    }

    @Test func loopbackRedirectHandsOverTheQueryAndAnswersTheBrowser() async throws {
        for host in ["127.0.0.1", "localhost"] {
            let redirect = try LoopbackRedirect(page: "Connected <done>")
            let port = try await redirect.start()
            let waiting = Task { try await redirect.callback() }
            let (data, response) = try await URLSession.shared.data(from: URL(string: "http://\(host):\(port)/?code=abc&state=xyz")!)
            let items = try await waiting.value
            redirect.cancel()
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self).contains("Connected &lt;done>"))
            #expect(items.contains(URLQueryItem(name: "code", value: "abc")) && items.contains(URLQueryItem(name: "state", value: "xyz")))
        }
    }
}

@MainActor @Suite struct DashboardCalendarTests {
    @Test func mergesConnectedSourcesAndFollowsConnectAndDisconnect() async throws {
        let world = try World()
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let noon = today.addingTimeInterval(12 * 3600)
        let apple = FakeCalendar(.apple, .connected, events: [
            event("a1", "Design review", at: noon, source: .apple, uid: "u1"),
            event("a2", "Holiday", at: today, minutes: 24 * 60, source: .apple, allDay: true),
        ])
        let google = FakeCalendar(.google, .disconnected, events: [
            event("g1", "Design review", at: noon, source: .google, link: "https://meet.google.com/x", uid: "u1"),
            event("g2", "1:1", at: noon.addingTimeInterval(3600), source: .google),
        ])
        let outlook = FakeCalendar(.microsoft, .unavailable)
        let dashboard = DashboardModel(
            library: world.library, voiceprints: world.app.voiceprints, settings: world.app.settings,
            calendars: [apple, google, outlook], todosFile: world.root.appending(path: "todos.json"), now: { now })

        await dashboard.reload()
        #expect(dashboard.calendarSources.map(\.connection) == [.connected, .disconnected, .unavailable])
        #expect(dashboard.events(on: today).map(\.id) == ["a2", "a1"], "all-day first")
        #expect(dashboard.selectedDay == today)
        #expect(dashboard.gridDays.contains(today))

        await dashboard.connect(.google)
        #expect(dashboard.calendarSources[1].connection == .connected)
        #expect(dashboard.events(on: today).map(\.id) == ["a2", "g1", "g2"])
        #expect(dashboard.events(on: today).first { $0.id == "g1" }?.link != nil)

        await dashboard.disconnect(.google)
        #expect(dashboard.events(on: today).map(\.id) == ["a2", "a1"])

        await dashboard.showMonth(1)
        #expect(!Calendar.current.isDate(dashboard.month, equalTo: today, toGranularity: .month))
        #expect(dashboard.selectedDay == dashboard.month)
        await dashboard.showToday()
        #expect(dashboard.selectedDay == today)

        apple.failure.set(.signedOut)
        apple.connection.set(.disconnected)
        await dashboard.reloadCalendar()
        #expect(dashboard.calendarSources[0].connection == .disconnected)
        #expect(dashboard.monthEvents.isEmpty)
    }

    @Test func aFailingSourceIsMarkedWhileTheOthersStillShow() async throws {
        let world = try World()
        let now = Date()
        let apple = FakeCalendar(.apple, .connected, events: [event("a1", "Standup", at: now, source: .apple)])
        let google = FakeCalendar(.google, .connected)
        google.failure.set(.unreachable)
        let dashboard = DashboardModel(
            library: world.library, voiceprints: world.app.voiceprints, settings: world.app.settings,
            calendars: [apple, google], todosFile: world.root.appending(path: "todos.json"), now: { now })
        await dashboard.reloadCalendar()
        #expect(dashboard.monthEvents.map(\.id) == ["a1"])
        #expect(dashboard.calendarSources[1].problem == .unreachable)
        #expect(dashboard.calendarSources[0].problem == nil)
    }
}
