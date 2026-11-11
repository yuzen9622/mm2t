import Foundation
import MM2TCore
import Testing
@testable import MM2TSystem

@Suite struct AppOwnershipTests {
    static let bundles = [
        "/Applications/Google Chrome.app": "com.google.Chrome",
        "/Applications/Safari.app": "com.apple.Safari",
        "/Applications/Microsoft Teams.app": "com.microsoft.teams2",
        "/Applications/zoom.us.app": "us.zoom.xos",
        "/System/Applications/Utilities/Terminal.app": "com.apple.Terminal",
    ]

    func owner(_ process: ProcessIdentity, responsible: ProcessIdentity? = nil) -> String? {
        AppOwnership.owner(of: process, responsible: responsible) { Self.bundles[$0] }
    }

    @Test func browserHelperResolvesToTheBrowser() {
        let helper = ProcessIdentity(
            pid: 20, bundleID: "com.google.Chrome.helper",
            executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/157.0/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper")
        #expect(owner(helper) == "com.google.Chrome")
    }

    @Test func electronHelperResolvesToTheApp() {
        let helper = ProcessIdentity(
            pid: 21, bundleID: "com.microsoft.teams2.helper",
            executablePath: "/Applications/Microsoft Teams.app/Contents/Helpers/Microsoft Teams WebView.app/Contents/MacOS/Microsoft Teams WebView")
        #expect(owner(helper) == "com.microsoft.teams2")
    }

    @Test func webKitGPUProcessResolvesThroughTheResponsibleApp() {
        let gpu = ProcessIdentity(
            pid: 30, bundleID: "com.apple.WebKit.GPU",
            executablePath: "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU")
        let safari = ProcessIdentity(pid: 31, bundleID: "com.apple.Safari", executablePath: "/Applications/Safari.app/Contents/MacOS/Safari")
        #expect(owner(gpu, responsible: safari) == "com.apple.Safari")
        #expect(owner(gpu) == "com.apple.WebKit.GPU")
    }

    @Test func aCommandLineToolBelongsToTheAppThatLaunchedIt() {
        let tool = ProcessIdentity(pid: 40, bundleID: nil, executablePath: "/usr/bin/afplay")
        let terminal = ProcessIdentity(pid: 41, bundleID: "com.apple.Terminal",
                                       executablePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
        #expect(owner(tool, responsible: terminal) == "com.apple.Terminal")
        #expect(owner(tool) == nil)
    }

    @Test func anAppIsItsOwnOwnerEvenWhenSomethingElseLaunchedIt() {
        let zoom = ProcessIdentity(pid: 50, bundleID: "us.zoom.xos", executablePath: "/Applications/zoom.us.app/Contents/MacOS/zoom.us")
        let terminal = ProcessIdentity(pid: 41, bundleID: "com.apple.Terminal",
                                       executablePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
        #expect(owner(zoom, responsible: terminal) == "us.zoom.xos")
    }

    @Test func outermostAppBundle() {
        #expect(AppOwnership.outermostAppBundle(in: "/Applications/A.app/Contents/Helpers/B.app/Contents/MacOS/B") == "/Applications/A.app")
        #expect(AppOwnership.outermostAppBundle(in: "/Applications/A.app") == "/Applications/A.app")
        #expect(AppOwnership.outermostAppBundle(in: "/usr/libexec/x.application/bin") == nil)
        #expect(AppOwnership.outermostAppBundle(in: "/usr/bin/afplay") == nil)
    }
}

@Suite struct SignalAssemblerTests {
    func client(_ pid: pid_t, _ owner: String?, input: Bool = true, output: Bool = false) -> AudioClient {
        AudioClient(pid: pid, ownerBundleID: owner, isRunningInput: input, isRunningOutput: output)
    }

    @Test func micUseCountsOnlyOtherProcessesRunningInput() {
        var assembler = SignalAssembler(ownPID: 1)
        let signals = assembler.assemble(RawSignals(clients: [
            client(1, "dev.mm2t"),
            client(2, "us.zoom.xos"),
            client(3, "com.google.Chrome", input: false, output: true),
            client(4, nil),
            client(5, "com.google.Chrome"),
            client(6, "com.google.Chrome"),
        ], frontmostBundleID: "com.google.Chrome", frontmostWindowTitle: "Meet - abc-defg-hij",
           browserURL: URL(string: "https://meet.google.com/abc-defg-hij")), now: 0)

        #expect(signals == SystemSignals(
            micBundleIDs: ["us.zoom.xos", "com.google.Chrome"], frontmostBundleID: "com.google.Chrome",
            frontmostWindowTitle: "Meet - abc-defg-hij", browserURL: URL(string: "https://meet.google.com/abc-defg-hij")))
    }

    @Test func aBriefMicReleaseDoesNotEndTheMeetingButARealOneDoes() {
        var assembler = SignalAssembler(ownPID: 1, releaseGrace: 3)
        var current: DetectedMeeting?
        var events: [(Double, MeetingEvent)] = []
        let polls: [(Double, Bool)] = [(0, true), (1, false), (2, false), (3, true), (4, false), (6, false), (7.5, false), (8, false)]
        for (now, zoomUsesMic) in polls {
            let raw = RawSignals(clients: zoomUsesMic ? [client(2, "us.zoom.xos")] : [])
            let result = MeetingDetector.evaluate(assembler.assemble(raw, now: now), current: current)
            current = result.current
            events += result.events.map { (now, $0) }
        }
        let summary = events.map { now, event in
            switch event {
            case .detected(let meeting): "\(now) detected \(meeting.bundleID)"
            case .ended(let meeting): "\(now) ended \(meeting.bundleID)"
            }
        }
        #expect(summary == ["0.0 detected us.zoom.xos", "7.5 ended us.zoom.xos"])
    }
}

@Suite struct BrowserScriptingTests {
    @Test func scriptsExistOnlyForBrowsersThatExposeTheTabURL() throws {
        let chrome = try #require(BrowserScripting.activeTabScript("com.google.Chrome"))
        #expect(chrome.contains("URL of active tab of front window"))
        #expect(chrome.contains(#"application id "com.google.Chrome""#))
        #expect(try #require(BrowserScripting.activeTabScript("com.apple.Safari")).contains("URL of front document"))
        #expect(BrowserScripting.activeTabScript("org.mozilla.firefox") == nil)
        #expect(BrowserScripting.activeTabScript("us.zoom.xos") == nil)
        #expect(BrowserScripting.scriptableBrowsers == MeetingDetector.browsers.subtracting(["org.mozilla.firefox"]),
                "the URL is read for exactly the browsers the detector recognizes")
    }
}
