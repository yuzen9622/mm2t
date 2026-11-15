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

    /// nil for any other call app or website. Only these four are stored with a meeting, so
    /// meetings saved before other apps prompted still decode, and older builds read new ones.
    public let platform: MeetingPlatform?
    public let client: Client
    /// The process whose audio the recorder should tap.
    public let bundleID: String
    /// The site's domain for a browser call outside the meeting platforms; it names the call.
    public let domain: String?
    /// No rule covers this app or site yet, so the prompt also asks how to treat it next time.
    public var isUnlisted: Bool

    public init(platform: MeetingPlatform?, client: Client, bundleID: String, domain: String? = nil, isUnlisted: Bool = false) {
        self.platform = platform
        self.client = client
        self.bundleID = bundleID
        self.domain = domain
        self.isUnlisted = isUnlisted
    }
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
    /// Feed the previous result's `current` back in on the next poll. `declined` holds the bundle
    /// IDs of calls the user declined that may still hold the mic: they are never detected, so a
    /// long-lived voice channel (Discord) is not prompted again, yet does not hide other meetings.
    /// The caller owns the set and drops an app once it has released the mic.
    public static func evaluate(
        _ signals: SystemSignals,
        current: DetectedMeeting?,
        declined: Set<String> = [],
        rules: DetectionRules = DetectionRules()
    ) -> (current: DetectedMeeting?, events: [MeetingEvent]) {
        var candidates = signals
        candidates.micBundleIDs.subtract(declined)
        // A browser meeting keeps going when the user switches tabs or apps, so only
        // releasing the mic ends a meeting. A call the user has since silenced ("never ask", or
        // switched off in Settings) ends too, so an app that holds the mic all day does not hide
        // the next real meeting.
        if let current {
            if signals.micBundleIDs.contains(current.bundleID), !isSilenced(current, rules: rules) { return (current, []) }
            let next = detect(candidates, rules: rules)
            return (next, [.ended(current)] + (next.map { [.detected($0)] } ?? []))
        }
        let next = detect(candidates, rules: rules)
        return (next, next.map { [.detected($0)] } ?? [])
    }

    static func isSilenced(_ meeting: DetectedMeeting, rules: DetectionRules) -> Bool {
        if let platform = meeting.platform, meeting.client == .browser {
            return DetectionPolicy.decision(for: platform, rules: rules) == .silent
        }
        if let domain = meeting.domain { return rules.site(domain)?.prompts == false }
        return DetectionPolicy.decision(forApp: meeting.bundleID, rules: rules) == .silent
    }

    /// A call that prompts outright wins over one that would only ask to be learned.
    static func detect(_ signals: SystemSignals, rules: DetectionRules) -> DetectedMeeting? {
        var unlisted: DetectedMeeting?
        for bundleID in signals.micBundleIDs.sorted() where !browsers.contains(bundleID) {
            switch DetectionPolicy.decision(forApp: bundleID, rules: rules) {
            case .prompt:
                return DetectedMeeting(platform: DetectionPolicy.callApp(bundleID)?.platform, client: .desktop, bundleID: bundleID)
            case .learn:
                unlisted = unlisted ?? DetectedMeeting(platform: nil, client: .desktop, bundleID: bundleID, isUnlisted: true)
            case .silent:
                break
            }
        }
        let site = browserCall(signals, rules: rules)
        if let site, !site.isUnlisted { return site }
        return unlisted ?? site
    }

    /// Only the frontmost browser is seen, since only its tab URL and title can be read.
    static func browserCall(_ signals: SystemSignals, rules: DetectionRules) -> DetectedMeeting? {
        guard let browser = signals.frontmostBundleID, browsers.contains(browser),
              signals.micBundleIDs.contains(browser) else { return nil }
        let url = signals.browserURL
        if let platform = url.flatMap(webPlatform) ?? signals.frontmostWindowTitle.flatMap(titlePlatform) {
            guard DetectionPolicy.decision(for: platform, rules: rules) == .prompt else { return nil }
            return DetectedMeeting(platform: platform, client: .browser, bundleID: browser)
        }
        guard let url, let domain = DetectionPolicy.domain(of: url) else { return nil }
        let decision = DetectionPolicy.decision(forSite: url, rules: rules)
        guard decision != .silent else { return nil }
        return DetectedMeeting(platform: nil, client: .browser, bundleID: browser, domain: domain, isUnlisted: decision == .learn)
    }

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
