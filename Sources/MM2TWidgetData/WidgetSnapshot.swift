import Foundation
import Security

/// What the app hands the desktop widget: the next two days' timed meetings, the open to-do count
/// and whether a recording is running. The widget extension is sandboxed and cannot read the
/// calendars or the library itself, so this file is all it knows; it holds titles and call links
/// and nothing else, and the app rewrites it whenever any of that changes.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// Bumped on any change to the encoded shape; a widget reading another version shows nothing
    /// rather than misreading it, until the app that matches it rewrites the file.
    public static let currentVersion = 1

    public struct Event: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let start: Date
        public let end: Date
        /// The meeting's call address; only http and https ones are kept.
        public let link: URL?

        public init(id: String, title: String, start: Date, end: Date, link: URL?) {
            self.id = id
            self.title = title
            self.start = start
            self.end = end
            self.link = link.flatMap { WidgetLink.isWeb($0) ? $0 : nil }
        }
    }

    public enum Recording: Codable, Equatable, Sendable {
        /// The clock reads now minus `since`; pauses are already taken out of `since`.
        case running(since: Date)
        case paused(elapsed: TimeInterval)
    }

    public var version: Int
    /// Timed events that touch the covered days, by start time.
    public var events: [Event]
    /// The calendar was read up to here; a day past it is unknown rather than free.
    public var through: Date
    public var openTodos: Int
    public var recording: Recording?

    public init(events: [Event], through: Date, openTodos: Int, recording: Recording?) {
        version = Self.currentVersion
        self.events = events.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        self.through = through
        self.openTodos = openTodos
        self.recording = recording
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    /// Nil for a file that is missing, damaged or written by a different version.
    public static func decode(_ data: Data) -> WidgetSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data),
              snapshot.version == currentVersion else { return nil }
        return snapshot
    }
}

/// Where the snapshot lives and how a Join click comes back to the app.
public enum WidgetLink {
    public static let kind = "dev.mm2t.app.upcoming"
    public static let scheme = "mm2t"
    static let fileName = "widget.json"

    /// The macOS form of an app group, `<team>.dev.mm2t`: the system lets code signed by that team
    /// use it without a provisioning profile. Ad-hoc code has no team, so it has no group.
    public static func groupIdentifier(team: String) -> String { "\(team).dev.mm2t" }

    /// The snapshot file in the shared app group container, or nil when this copy is not signed
    /// by a team (an ad-hoc build), which the widget cannot share data with.
    public static func snapshotFile() -> URL? {
        guard let team = signingTeam(),
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: groupIdentifier(team: team)) else { return nil }
        return container.appending(path: fileName)
    }

    /// The team of the running code's own signature. Read from the signature rather than written
    /// into Info.plist, so the app and the widget agree on the group with nothing to keep in sync.
    static func signingTeam() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { return nil }
        return team
    }

    /// The widget's Join link names the event, never its address: the app opens only an address
    /// it wrote into the snapshot itself.
    public static func join(_ event: WidgetSnapshot.Event) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "join"
        components.queryItems = [URLQueryItem(name: "event", value: event.id)]
        return components.url!
    }

    /// The call address a Join link asks for, if `url` is one and the event is in `snapshot`.
    public static func meetingURL(for url: URL, in snapshot: WidgetSnapshot) -> URL? {
        guard url.scheme == scheme, url.host() == "join",
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "event" })?.value,
              let link = snapshot.events.first(where: { $0.id == id })?.link, isWeb(link) else { return nil }
        return link
    }

    static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && url.host() != nil
    }
}
