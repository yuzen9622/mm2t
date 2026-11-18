import Foundation

/// The user's answer for one app or website: whether mic use there brings up the recording prompt.
public struct DetectionRule: Codable, Hashable, Sendable {
    /// A bundle ID for an app, a domain for a website.
    public var key: String
    /// Kept with the rule so Settings can name an app that is no longer installed.
    public var name: String
    public var prompts: Bool

    public init(key: String, name: String, prompts: Bool) {
        self.key = key
        self.name = name
        self.prompts = prompts
    }
}

/// Every app and website the user has answered for. A rule on a built-in entry is the user
/// switching it off; a rule anywhere else is one the prompt learned or the user added by hand.
public struct DetectionRules: Codable, Hashable, Sendable {
    public var apps: [DetectionRule]
    public var sites: [DetectionRule]

    public init(apps: [DetectionRule] = [], sites: [DetectionRule] = []) {
        self.apps = apps
        self.sites = sites
    }

    public func app(_ bundleID: String) -> DetectionRule? {
        apps.first { $0.key == bundleID }
    }

    /// The rule for `host` or the closest parent domain, so a rule for `example.com` covers `app.example.com`.
    public func site(_ host: String) -> DetectionRule? {
        sites.filter { DetectionPolicy.host(host, isOn: $0.key) }.max { $0.key.count < $1.key.count }
    }

    /// Adds `rule` to `list`, replacing one with the same key.
    public mutating func set(_ rule: DetectionRule, in list: WritableKeyPath<DetectionRules, [DetectionRule]>) {
        if let index = self[keyPath: list].firstIndex(where: { $0.key == rule.key }) {
            self[keyPath: list][index] = rule
        } else {
            self[keyPath: list].append(rule)
        }
    }

    public mutating func remove(_ key: String, from list: WritableKeyPath<DetectionRules, [DetectionRule]>) {
        self[keyPath: list].removeAll { $0.key == key }
    }
}

/// What mic use in one app or on one site leads to.
public enum PromptDecision: Hashable, Sendable {
    case prompt
    /// Nothing covers it yet: prompt, and also ask whether to always prompt or never ask.
    case learn
    case silent
}

/// A call app that prompts unless the user switches it off. Apps with more than one bundle ID
/// (old and new builds) are one entry, so one switch covers them all.
public struct BuiltInCallApp: Hashable, Sendable {
    public let name: String
    public let bundleIDs: [String]
    public let platform: MeetingPlatform?
}

/// Pure decisions behind the recording prompt: the built-in call apps and meeting sites, the
/// built-in exclusions, and the user's rules. User rules come first, so any built-in entry can
/// be switched off and any excluded app can still be added by hand.
public enum DetectionPolicy {
    /// How each bundle ID was checked (2026-11):
    /// - Installed on the development Mac (`mdls`): Discord `com.hnc.Discord`, LINE
    ///   `jp.naver.line.mac`, FaceTime `com.apple.FaceTime`.
    /// - Homebrew cask `uninstall` stanzas (formulae.brew.sh): Slack `com.tinyspeck.slackmacgap`,
    ///   Telegram's App Store build `ru.keepcoder.Telegram`, WhatsApp `net.whatsapp.WhatsApp`.
    /// - Telegram Desktop `com.tdesktop.Telegram`: only the preferences file name in its cask's
    ///   cleanup list, so weaker than the rest.
    /// - Zoom, new Teams and Webex verified against public MDM catalogs; classic Teams
    ///   `com.microsoft.teams` and Webex Meetings `com.webex.meetingmanager` are from memory and unverified.
    public static let callApps: [BuiltInCallApp] = [
        BuiltInCallApp(name: "Zoom", bundleIDs: ["us.zoom.xos"], platform: .zoom),
        BuiltInCallApp(name: "Microsoft Teams", bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"], platform: .teams),
        BuiltInCallApp(name: "Webex", bundleIDs: ["Cisco-Systems.Spark", "com.webex.meetingmanager"], platform: .webex),
        BuiltInCallApp(name: "Discord", bundleIDs: ["com.hnc.Discord"], platform: nil),
        BuiltInCallApp(name: "FaceTime", bundleIDs: ["com.apple.FaceTime"], platform: nil),
        BuiltInCallApp(name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"], platform: nil),
        BuiltInCallApp(name: "LINE", bundleIDs: ["jp.naver.line.mac"], platform: nil),
        BuiltInCallApp(name: "Telegram", bundleIDs: ["ru.keepcoder.Telegram", "com.tdesktop.Telegram"], platform: nil),
        BuiltInCallApp(name: "WhatsApp", bundleIDs: ["net.whatsapp.WhatsApp"], platform: nil),
    ]

    /// Apps that use the mic for something other than a call never prompt and are never asked
    /// about. mm2t itself is `dev.mm2t.app` (project file); OBS, Audio Hijack, Superwhisper and
    /// MacWhisper are from their Homebrew cask `uninstall quit:` stanzas.
    ///
    /// Apple's dictation, Siri and recording tools are covered by `isExcluded` instead: the IDs
    /// on this Mac (Voice Memos `com.apple.VoiceMemos`, QuickTime Player `com.apple.QuickTimePlayerX`,
    /// Siri `com.apple.Siri`, dictation `com.apple.inputmethod.ironwood`, plus daemons such as
    /// `corespeechd`) change between macOS releases, and FaceTime is the only Apple call app.
    static let excludedApps: Set<String> = [
        "dev.mm2t.app",
        "com.obsproject.obs-studio",
        "com.rogueamoeba.audiohijack",
        "com.superduper.superwhisper",
        "com.goodsnooze.MacWhisper",
    ]

    public static func isExcluded(_ bundleID: String) -> Bool {
        excludedApps.contains(bundleID) || (bundleID.hasPrefix("com.apple.") && callApp(bundleID) == nil)
    }

    public static func callApp(_ bundleID: String) -> BuiltInCallApp? {
        callApps.first { $0.bundleIDs.contains(bundleID) }
    }

    public static func decision(forApp bundleID: String, rules: DetectionRules) -> PromptDecision {
        if let rule = rules.app(bundleID) { return rule.prompts ? .prompt : .silent }
        if callApp(bundleID) != nil { return .prompt }
        return isExcluded(bundleID) ? .silent : .learn
    }

    /// The meeting sites' own domains, the key a user rule switches each one off with.
    public static func siteDomain(_ platform: MeetingPlatform) -> String {
        switch platform {
        case .googleMeet: "meet.google.com"
        case .zoom: "zoom.us"
        case .teams: "teams.microsoft.com"
        case .webex: "webex.com"
        }
    }

    /// A known meeting site prompts only on a meeting page: the rest of the site (a landing or
    /// pricing page) is silent rather than learned, since the site is already known.
    public static func decision(forSite url: URL, rules: DetectionRules) -> PromptDecision {
        guard let host = domain(of: url) else { return .silent }
        if let platform = MeetingDetector.webPlatform(url) { return decision(for: platform, rules: rules) }
        if MeetingPlatform.allCases.contains(where: { Self.host(host, isOn: siteDomain($0)) }) { return .silent }
        if let rule = rules.site(host) { return rule.prompts ? .prompt : .silent }
        return .learn
    }

    /// A meeting recognised by its page, switched off only by a rule on the site's own domain.
    public static func decision(for platform: MeetingPlatform, rules: DetectionRules) -> PromptDecision {
        rules.sites.first { $0.key == siteDomain(platform) }?.prompts == false ? .silent : .prompt
    }

    /// The domain a site rule is stored under: the lowercased host without a leading `www.`.
    public static func domain(of url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Parses a website the user typed, with or without a scheme or path; nil for anything
    /// without a dot in its host.
    public static func domain(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")
        guard let domain = url.flatMap(domain(of:)), domain.contains("."),
              !domain.hasPrefix("."), !domain.hasSuffix(".") else { return nil }
        return domain
    }

    static func host(_ host: String, isOn domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }
}
