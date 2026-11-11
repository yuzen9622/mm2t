import Foundation

public enum MeetingPlatform: String, Codable, Hashable, Sendable, CaseIterable {
    case zoom
    case teams
    case webex
    case googleMeet
}

public struct DetectedMeeting: Hashable, Sendable {
    public enum Client: Hashable, Sendable {
        case desktop
        case browser
    }

    public let platform: MeetingPlatform
    public let client: Client
    /// The process whose audio the recorder should tap.
    public let bundleID: String
}

/// One poll of system state, supplied by the app's signal sources.
public struct SystemSignals: Hashable, Sendable {
    /// Bundle IDs of the apps responsible for current mic use; helper processes
    /// (e.g. a browser's audio service) must already be resolved to their parent app.
    public var micBundleIDs: Set<String>
    public var frontmostBundleID: String?
    public var frontmostWindowTitle: String?
    /// URL of the frontmost browser's active tab.
    public var browserURL: URL?

    public init(micBundleIDs: Set<String>, frontmostBundleID: String? = nil,
                frontmostWindowTitle: String? = nil, browserURL: URL? = nil) {
        self.micBundleIDs = micBundleIDs
        self.frontmostBundleID = frontmostBundleID
        self.frontmostWindowTitle = frontmostWindowTitle
        self.browserURL = browserURL
    }
}

public enum MeetingEvent: Hashable, Sendable {
    case detected(DetectedMeeting)
    case ended(DetectedMeeting)
}

public enum MeetingDetector {
    /// Feed the previous result's `current` back in on the next poll.
    public static func evaluate(
        _ signals: SystemSignals,
        current: DetectedMeeting?
    ) -> (current: DetectedMeeting?, events: [MeetingEvent]) {
        // A browser meeting keeps going when the user switches tabs or apps, so only
        // releasing the mic ends a meeting.
        if let current {
            if signals.micBundleIDs.contains(current.bundleID) { return (current, []) }
            let next = detect(signals)
            return (next, [.ended(current)] + (next.map { [.detected($0)] } ?? []))
        }
        let next = detect(signals)
        return (next, next.map { [.detected($0)] } ?? [])
    }

    static func detect(_ signals: SystemSignals) -> DetectedMeeting? {
        for (bundleID, platform) in desktopApps.sorted(by: { $0.key < $1.key })
        where signals.micBundleIDs.contains(bundleID) {
            return DetectedMeeting(platform: platform, client: .desktop, bundleID: bundleID)
        }
        guard let browser = signals.frontmostBundleID, browsers.contains(browser),
              signals.micBundleIDs.contains(browser),
              let platform = signals.browserURL.flatMap(webPlatform) ?? signals.frontmostWindowTitle.flatMap(titlePlatform)
        else { return nil }
        return DetectedMeeting(platform: platform, client: .browser, bundleID: browser)
    }

    /// Zoom, new Teams and Webex verified against public MDM catalogs; classic Teams and
    /// Webex Meetings are from memory and unverified.
    static let desktopApps: [String: MeetingPlatform] = [
        "us.zoom.xos": .zoom,
        "com.microsoft.teams2": .teams,
        "com.microsoft.teams": .teams,
        "Cisco-Systems.Spark": .webex,
        "com.webex.meetingmanager": .webex,
    ]

    /// Chrome and Safari verified on a local install; the rest from memory.
    public static let browsers: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",
        "com.brave.Browser",
    ]

    static func webPlatform(_ url: URL) -> MeetingPlatform? {
        guard let host = url.host()?.lowercased() else { return nil }
        let path = url.path()
        if host == "meet.google.com", path.wholeMatch(of: meetCode) != nil { return .googleMeet }
        if host == "zoom.us" || host.hasSuffix(".zoom.us"), path.hasPrefix("/wc/") { return .zoom }
        if ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"].contains(host) { return .teams }
        if host.hasSuffix(".webex.com") { return .webex }
        return nil
    }

    static func titlePlatform(_ title: String) -> MeetingPlatform? {
        title.firstMatch(of: meetTitle) != nil ? .googleMeet : nil
    }

    nonisolated(unsafe) static let meetCode = /\/[a-z]{3}-[a-z]{4}-[a-z]{3}\/?/
    nonisolated(unsafe) static let meetTitle = /^Meet [-–] [a-z]{3}-[a-z]{4}-[a-z]{3}/
}
