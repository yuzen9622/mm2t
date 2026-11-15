import Foundation
import Testing
@testable import MM2TCore

@Suite struct DetectionRulesTests {
    static func browser(_ url: String) -> SystemSignals {
        SystemSignals(micBundleIDs: ["com.google.Chrome"], frontmostBundleID: "com.google.Chrome", browserURL: URL(string: url))
    }

    static func detected(_ signals: SystemSignals, rules: DetectionRules = DetectionRules()) -> DetectedMeeting? {
        MeetingDetector.evaluate(signals, current: nil, rules: rules).current
    }

    @Test(arguments: ["com.hnc.Discord", "com.apple.FaceTime", "com.tinyspeck.slackmacgap", "jp.naver.line.mac",
                      "ru.keepcoder.Telegram", "com.tdesktop.Telegram", "net.whatsapp.WhatsApp"])
    func aBuiltInCallAppPromptsWithoutAskingToLearn(_ bundleID: String) {
        let meeting = Self.detected(SystemSignals(micBundleIDs: [bundleID]))
        #expect(meeting == DetectedMeeting(platform: nil, client: .desktop, bundleID: bundleID))
        #expect(meeting?.isUnlisted == false)
    }

    @Test(arguments: ["dev.mm2t.app", "com.apple.VoiceMemos", "com.apple.QuickTimePlayerX", "com.apple.Siri",
                      "com.apple.inputmethod.ironwood", "com.apple.corespeechd", "com.obsproject.obs-studio"])
    func anExcludedAppNeverPrompts(_ bundleID: String) {
        #expect(Self.detected(SystemSignals(micBundleIDs: [bundleID])) == nil)
    }

    @Test func anUnknownAppAsksToBeLearned() {
        let meeting = Self.detected(SystemSignals(micBundleIDs: ["com.example.Caller"]))
        #expect(meeting == DetectedMeeting(platform: nil, client: .desktop, bundleID: "com.example.Caller", isUnlisted: true))
    }

    @Test func aNeverRuleSilencesAnAppAndAnAlwaysRulePromptsWithoutLearning() {
        let signals = SystemSignals(micBundleIDs: ["com.example.Caller"])
        let never = DetectionRules(apps: [DetectionRule(key: "com.example.Caller", name: "Caller", prompts: false)])
        #expect(Self.detected(signals, rules: never) == nil)

        let always = DetectionRules(apps: [DetectionRule(key: "com.example.Caller", name: "Caller", prompts: true)])
        #expect(Self.detected(signals, rules: always)?.isUnlisted == false)
    }

    @Test func switchingOffABuiltInAppSilencesIt() {
        let off = DetectionRules(apps: [DetectionRule(key: "com.hnc.Discord", name: "Discord", prompts: false)])
        #expect(Self.detected(SystemSignals(micBundleIDs: ["com.hnc.Discord"]), rules: off) == nil)
        let zoomOff = DetectionRules(apps: [DetectionRule(key: "us.zoom.xos", name: "Zoom", prompts: false)])
        #expect(Self.detected(SystemSignals(micBundleIDs: ["us.zoom.xos"]), rules: zoomOff) == nil)
    }

    @Test func aPromptingAppWinsOverOneThatWouldOnlyBeLearned() {
        let meeting = Self.detected(SystemSignals(micBundleIDs: ["com.example.Caller", "us.zoom.xos"]))
        #expect(meeting?.bundleID == "us.zoom.xos")
    }

    @Test func anUnknownSiteAsksToBeLearnedByDomain() {
        let meeting = Self.detected(Self.browser("https://www.gather.town/app/room"))
        #expect(meeting == DetectedMeeting(platform: nil, client: .browser, bundleID: "com.google.Chrome",
                                           domain: "gather.town", isUnlisted: true))
    }

    @Test func siteRulesCoverSubdomainsAndTheClosestRuleWins() {
        let rules = DetectionRules(sites: [
            DetectionRule(key: "gather.town", name: "gather.town", prompts: true),
            DetectionRule(key: "quiet.gather.town", name: "quiet.gather.town", prompts: false),
        ])
        let app = Self.detected(Self.browser("https://app.gather.town/x"), rules: rules)
        #expect(app?.domain == "app.gather.town" && app?.isUnlisted == false)
        #expect(Self.detected(Self.browser("https://quiet.gather.town/x"), rules: rules) == nil)
        let never = DetectionRules(sites: [DetectionRule(key: "gather.town", name: "gather.town", prompts: false)])
        #expect(Self.detected(Self.browser("https://gather.town"), rules: never) == nil)
    }

    @Test func switchingOffABuiltInSiteSilencesItsMeetingsOnly() {
        let off = DetectionRules(sites: [DetectionRule(key: "meet.google.com", name: "meet.google.com", prompts: false)])
        #expect(Self.detected(Self.browser("https://meet.google.com/abc-defg-hij"), rules: off) == nil)
        let byTitle = SystemSignals(micBundleIDs: ["com.apple.Safari"], frontmostBundleID: "com.apple.Safari",
                                    frontmostWindowTitle: "Meet - abc-defg-hij")
        #expect(Self.detected(byTitle, rules: off) == nil)
        #expect(Self.detected(Self.browser("https://acme.zoom.us/wc/81234567890/join"), rules: off)?.platform == .zoom)
    }

    @Test func aKnownMeetingSiteOutsideAMeetingIsSilentNotLearned() {
        #expect(Self.detected(Self.browser("https://zoom.us/pricing")) == nil)
        #expect(Self.detected(Self.browser("https://meet.google.com/landing")) == nil)
    }

    @Test func aTrackedVoiceChannelIsDetectedOnceUntilTheMicIsReleased() {
        let discord = SystemSignals(micBundleIDs: ["com.hnc.Discord"])
        let start = MeetingDetector.evaluate(discord, current: nil)
        #expect(start.events.count == 1)
        // Being recorded or prompted; the voice channel stays open for hours.
        var current = start.current
        for _ in 0..<3 {
            let poll = MeetingDetector.evaluate(discord, current: current)
            #expect(poll.events.isEmpty)
            current = poll.current
        }
        let released = MeetingDetector.evaluate(SystemSignals(micBundleIDs: []), current: current)
        #expect(released.events == [.ended(start.current!)])
        let rejoined = MeetingDetector.evaluate(discord, current: released.current)
        #expect(rejoined.events == [.detected(start.current!)])
    }

    @Test func silencingTheCurrentCallLetsTheNextMeetingPrompt() throws {
        let first = MeetingDetector.evaluate(SystemSignals(micBundleIDs: ["com.example.Caller"]), current: nil)
        let unlisted = try #require(first.current)
        let never = DetectionRules(apps: [DetectionRule(key: "com.example.Caller", name: "Caller", prompts: false)])

        let next = MeetingDetector.evaluate(SystemSignals(micBundleIDs: ["com.example.Caller", "us.zoom.xos"]),
                                            current: unlisted, rules: never)
        let zoom = DetectedMeeting(platform: .zoom, client: .desktop, bundleID: "us.zoom.xos")
        #expect(next.events == [.ended(unlisted), .detected(zoom)])
    }

    @Test func aDeclinedCallIsSkippedSoAnotherMeetingIsDetectedAndItsEndDoesNotBringTheDeclinedOneBack() {
        let declined: Set<String> = ["com.hnc.Discord"]
        #expect(MeetingDetector.evaluate(SystemSignals(micBundleIDs: ["com.hnc.Discord"]), current: nil, declined: declined).events.isEmpty)

        let zoom = DetectedMeeting(platform: .zoom, client: .desktop, bundleID: "us.zoom.xos")
        let start = MeetingDetector.evaluate(SystemSignals(micBundleIDs: ["com.hnc.Discord", "us.zoom.xos"]), current: nil, declined: declined)
        #expect(start.events == [.detected(zoom)])

        let end = MeetingDetector.evaluate(SystemSignals(micBundleIDs: ["com.hnc.Discord"]), current: start.current, declined: declined)
        #expect(end.events == [.ended(zoom)])
        #expect(end.current == nil)
    }

    @Test func aDeclinedBrowserSkipsItsSitesAndTheTrackedCallIsNeverReplaced() {
        let meet = SystemSignals(micBundleIDs: ["com.google.Chrome"], frontmostBundleID: "com.google.Chrome",
                                 browserURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        #expect(MeetingDetector.evaluate(meet, current: nil, declined: ["com.google.Chrome"]).events.isEmpty)

        let discord = DetectedMeeting(platform: nil, client: .desktop, bundleID: "com.hnc.Discord")
        let both = MeetingDetector.evaluate(SystemSignals(micBundleIDs: ["com.hnc.Discord", "us.zoom.xos"]), current: discord)
        #expect(both.events.isEmpty)
        #expect(both.current == discord)
    }

    @Test func typedWebsitesParseToADomain() {
        #expect(DetectionPolicy.domain(from: " https://www.Gather.town/app ") == "gather.town")
        #expect(DetectionPolicy.domain(from: "app.gather.town/x") == "app.gather.town")
        #expect(DetectionPolicy.domain(from: "not a site") == nil)
        #expect(DetectionPolicy.domain(from: "localhost") == nil)
        #expect(DetectionPolicy.domain(from: "") == nil)
    }
}
