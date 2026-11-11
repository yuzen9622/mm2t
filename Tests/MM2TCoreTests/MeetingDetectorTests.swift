import Foundation
import Testing
@testable import MM2TCore

@Suite struct MeetingDetectorTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let signals: SystemSignals
        let expected: DetectedMeeting
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "Zoom desktop", signals: SystemSignals(micBundleIDs: ["us.zoom.xos"]),
             expected: DetectedMeeting(platform: .zoom, client: .desktop, bundleID: "us.zoom.xos")),
        Case(name: "Teams desktop", signals: SystemSignals(micBundleIDs: ["com.microsoft.teams2"]),
             expected: DetectedMeeting(platform: .teams, client: .desktop, bundleID: "com.microsoft.teams2")),
        Case(name: "Webex desktop", signals: SystemSignals(micBundleIDs: ["Cisco-Systems.Spark"]),
             expected: DetectedMeeting(platform: .webex, client: .desktop, bundleID: "Cisco-Systems.Spark")),
        Case(name: "Google Meet in Chrome",
             signals: browser("com.google.Chrome", url: "https://meet.google.com/abc-defg-hij?authuser=0"),
             expected: DetectedMeeting(platform: .googleMeet, client: .browser, bundleID: "com.google.Chrome")),
        Case(name: "Google Meet by window title",
             signals: SystemSignals(micBundleIDs: ["com.apple.Safari"], frontmostBundleID: "com.apple.Safari",
                                    frontmostWindowTitle: "Meet - abc-defg-hij"),
             expected: DetectedMeeting(platform: .googleMeet, client: .browser, bundleID: "com.apple.Safari")),
        Case(name: "Zoom web", signals: browser("com.google.Chrome", url: "https://app.zoom.us/wc/81234567890/join"),
             expected: DetectedMeeting(platform: .zoom, client: .browser, bundleID: "com.google.Chrome")),
        Case(name: "Teams web", signals: browser("com.microsoft.edgemac", url: "https://teams.microsoft.com/v2/"),
             expected: DetectedMeeting(platform: .teams, client: .browser, bundleID: "com.microsoft.edgemac")),
        Case(name: "Webex web", signals: browser("com.apple.Safari", url: "https://acme.webex.com/meet/jdoe"),
             expected: DetectedMeeting(platform: .webex, client: .browser, bundleID: "com.apple.Safari")),
    ]

    static func browser(_ bundleID: String, url: String) -> SystemSignals {
        SystemSignals(micBundleIDs: [bundleID], frontmostBundleID: bundleID, browserURL: URL(string: url))
    }

    @Test(arguments: cases)
    func detectsTheMeetingOnceAndEndsWhenTheMicIsReleased(_ c: Case) {
        let start = MeetingDetector.evaluate(c.signals, current: nil)
        #expect(start.events == [.detected(c.expected)])

        let ongoing = MeetingDetector.evaluate(c.signals, current: start.current)
        #expect(ongoing.events.isEmpty)
        #expect(ongoing.current == c.expected)

        let end = MeetingDetector.evaluate(SystemSignals(micBundleIDs: []), current: ongoing.current)
        #expect(end.events == [.ended(c.expected)])
        #expect(end.current == nil)
    }

    @Test func switchingAwayFromABrowserMeetingDoesNotEndIt() {
        let meet = MeetingDetector.evaluate(Self.browser("com.google.Chrome", url: "https://meet.google.com/abc-defg-hij"), current: nil)
        let elsewhere = SystemSignals(micBundleIDs: ["com.google.Chrome"], frontmostBundleID: "com.apple.finder")

        let next = MeetingDetector.evaluate(elsewhere, current: meet.current)

        #expect(next.events.isEmpty)
        #expect(next.current == meet.current)
    }

    @Test func micUseOutsideAMeetingIsIgnored() {
        let cases = [
            SystemSignals(micBundleIDs: ["com.apple.VoiceMemos"]),
            Self.browser("com.google.Chrome", url: "https://meet.google.com/landing"),
            Self.browser("com.google.Chrome", url: "https://www.youtube.com/watch?v=x"),
            Self.browser("com.google.Chrome", url: "https://zoom.us/pricing"),
            SystemSignals(micBundleIDs: [], frontmostBundleID: "com.google.Chrome",
                          browserURL: URL(string: "https://meet.google.com/abc-defg-hij")),
        ]
        for signals in cases {
            #expect(MeetingDetector.evaluate(signals, current: nil).events.isEmpty, "\(signals)")
        }
    }

    @Test func endingOneMeetingWhileAnotherStartsReportsBoth() {
        let zoom = DetectedMeeting(platform: .zoom, client: .desktop, bundleID: "us.zoom.xos")
        let result = MeetingDetector.evaluate(SystemSignals(micBundleIDs: ["com.microsoft.teams2"]), current: zoom)
        let teams = DetectedMeeting(platform: .teams, client: .desktop, bundleID: "com.microsoft.teams2")
        #expect(result.events == [.ended(zoom), .detected(teams)])
        #expect(result.current == teams)
    }
}
