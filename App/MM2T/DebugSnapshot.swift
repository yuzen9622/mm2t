import AppKit
import MM2TApp
import MM2TCore
import MM2TProviders
import SwiftUI

/// Debug-build verification hook. With `MM2T_SNAPSHOT_DIR` set, the app opens a processed meeting,
/// renders each of the four views to PNG in-process (screen capture is excluded by design), shows
/// the meeting prompt, records how the window server reports every window's sharing state, and quits.
@MainActor
enum DebugSnapshot {
    #if DEBUG
    static let directory = ProcessInfo.processInfo.environment["MM2T_SNAPSHOT_DIR"].map { URL(filePath: $0) }
    #else
    static let directory: URL? = nil
    #endif
    static var isRequested: Bool { directory != nil }

    private static var selectMeeting: ((MeetingID) -> Void)?
    private static var showSection: ((SidebarItem) -> Void)?
    private static weak var detail: MeetingDetailModel?

    static func mainWindowAppeared(select: @escaping (MeetingID) -> Void, show: @escaping (SidebarItem) -> Void) {
        guard isRequested else { return }
        selectMeeting = select
        showSection = show
    }

    static func detailAppeared(_ model: MeetingDetailModel) {
        guard isRequested else { return }
        detail = model
    }

    static func run(app: AppController) {
        #if DEBUG
        guard let directory else { return }
        Task {
            var report: [String: Any] = [:]
            WindowOpener.open(WindowID.main)
            await waitFor { selectMeeting != nil && !app.meetings.rows.isEmpty }
            guard let meeting = app.meetings.rows.first(where: { $0.status == .completed }) else {
                report["error"] = "no completed meeting in \(app.paths.meetings.path)"
                return finish(report, in: directory)
            }
            try? await Task.sleep(for: .milliseconds(1800))
            save(window(titled: true), to: directory.appending(path: "main-home.png"))
            await saveHomeVariants(app: app, to: directory)
            for (section, name) in [(SidebarItem.vocabulary, "vocabulary"), (.settings, "settings"), (.meetings, "list")] {
                showSection?(section)
                try? await Task.sleep(for: .milliseconds(900))
                save(window(titled: true), to: directory.appending(path: "main-\(name).png"))
            }
            saveCapsules(to: directory)
            saveTips(to: directory)
            selectMeeting?(meeting.id)
            await waitFor { detail?.presentation != nil }
            for view in TranscriptView.allCases {
                detail?.selectedView = view
                try? await Task.sleep(for: .milliseconds(800))
                save(window(titled: true), to: directory.appending(path: "main-\(view.rawValue).png"))
            }
            if let jump = detail?.presentation?.summary?.decisions.first?.jump {
                detail?.jump(to: jump)
                detail?.playback?.pause()
                try? await Task.sleep(for: .milliseconds(800))
                save(window(titled: true), to: directory.appending(path: "main-jump-from-summary.png"))
                report["jumpLandedOn"] = detail?.focusedUtterance?.rawValue
                report["jumpTime"] = jump.time
            }
            WindowOpener.open(WindowID.onboarding)
            try? await Task.sleep(for: .milliseconds(800))
            if let onboarding = NSApp.windows.first(where: { $0.isVisible && $0.title != app.meetings.rows.first?.title && $0 !== window(titled: true) && $0.styleMask.contains(.titled) }) {
                save(onboarding, to: directory.appending(path: "onboarding.png"))
            }

            await app.capture.handle(SystemSignals(micBundleIDs: ["us.zoom.xos"]))
            try? await Task.sleep(for: .milliseconds(800))
            if let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0.level == .statusBar }) {
                save(panel, to: directory.appending(path: "prompt-panel.png"))
                report["promptPanelFrame"] = NSStringFromRect(panel.frame)
                report["promptPanelScreen"] = panel.screen?.localizedName
            }
            report["windows"] = sharingReport()
            app.capture.dismiss()
            finish(report, in: directory)
        }
        #endif
    }

    /// Calendar sources with fixed events around today, so the dashboard's calendar can be judged
    /// without signing in anywhere. Outlook stays unavailable, as in a build without its client ID.
    static var sampleCalendars: [any CalendarSource]? {
        #if DEBUG
        guard isRequested else { return nil }
        return [SampleCalendar(.apple, .connected), SampleCalendar(.google, .connected), SampleCalendar(.microsoft, .unavailable)]
        #else
        return nil
        #endif
    }

    /// The dashboard at the window's minimum size and in dark mode, and the calendar card before any
    /// source is connected.
    private static func saveHomeVariants(app: AppController, to directory: URL) async {
        #if DEBUG
        guard let main = window(titled: true) else { return }
        let size = main.frame.size
        main.setContentSize(NSSize(width: 820, height: 540))
        try? await Task.sleep(for: .milliseconds(900))
        save(main, to: directory.appending(path: "main-home-min.png"))
        main.setContentSize(NSSize(width: 980, height: 680))
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? await Task.sleep(for: .milliseconds(900))
        save(main, to: directory.appending(path: "main-home-dark.png"))
        NSApp.appearance = nil
        main.setFrame(NSRect(origin: main.frame.origin, size: size), display: true)

        let fresh = DashboardModel(
            library: app.library, voiceprints: app.voiceprints, settings: app.settings,
            calendars: [SampleCalendar(.apple, .disconnected), SampleCalendar(.google, .disconnected), SampleCalendar(.microsoft, .unavailable)],
            todosFile: directory.appending(path: "todos.json"), now: Date.init)
        await fresh.reloadCalendar()
        render(CalendarCard(model: fresh).frame(width: 700).padding(24).background(Palette.window), to: directory.appending(path: "calendar-connect.png"))
        render(CalendarSourceList(model: app.dashboard).frame(width: 308).padding(16).background(Palette.card),
               to: directory.appending(path: "calendar-sources.png"))
        #endif
    }

    private static func render(_ view: some View, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Tooltips on controls in a window's corners and middle, to show each one stays inside it.
    private static func saveTips(to directory: URL) {
        #if DEBUG
        let size = CGSize(width: 360, height: 150)
        func control(_ title: LocalizedStringKey) -> some View {
            Circle().fill(Palette.hover).frame(width: 32, height: 32).tip(title, show: true)
        }
        let view = VStack {
            HStack { control("Back"); Spacer(); control("Play"); Spacer(); control("Speakers") }
            Spacer()
            HStack { control("Rename…"); Spacer(); control("Copy"); Spacer(); control("Delete…") }
        }
        .padding(8)
        .frame(width: size.width, height: size.height)
        .background(Palette.window)
        .environment(\.tipBounds, size)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "tips.png"))
        #endif
    }

    /// The capsule's states drawn with fixed values, since no recording runs during a snapshot.
    private static func saveCapsules(to directory: URL) {
        #if DEBUG
        let speech = [0.9, 0.7, 0.95, 0.6, 0.8, 0.5]
        func bar(paused: Bool = false, silent: Bool = false, hover: Bool = false) -> some View {
            CapsuleBar(isPaused: paused, level: 0.8, elapsed: 768, remoteSilent: silent, showsHighlight: hover || paused,
                       hasHighlights: false, toggle: {}, highlight: {}, finish: {})
                .capsuleChrome()
        }
        let view = VStack(alignment: .center, spacing: 14) {
            bar().environment(\.snapshotWaveform, speech)
            bar(hover: true).environment(\.snapshotWaveform, speech)
            bar(paused: true)
            bar(silent: true)
            Working(text: "Transcribing").capsuleChrome()
            HStack(spacing: 10) {
                Status(icon: "video", text: LocalizedStringKey(stringLiteral: "Zoom 會議"))
                CapsulePill("Record", filled: true) {}
                CircleButton("Not This Time", icon: "x") {}
            }
            .capsuleChrome()
            Status(icon: "circle-check", tint: Palette.success, text: LocalizedStringKey(stringLiteral: "產品週會")).capsuleChrome()
        }
        .padding(24)
        .background(Color(white: 0.45))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "capsules.png"))
        #endif
    }

    private static func window(titled: Bool) -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && $0.identifier?.rawValue.contains(WindowID.main) == true }
            ?? NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) }
    }

    private static func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// Renders the window's own view tree; this reads the app's views, not the screen.
    private static func save(_ window: NSWindow?, to url: URL) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// For every visible window: the sharing type AppKit holds and the sharing state the window server
    /// reports to other processes (0 means capture services leave the window out).
    private static func sharingReport() -> [[String: Any]] {
        let info = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        let pid = ProcessInfo.processInfo.processIdentifier
        return NSApp.windows.filter(\.isVisible).map { window in
            let number = window.windowNumber
            let server = info.first { ($0[kCGWindowNumber as String] as? Int) == number && ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
            let entry: [String: Any] = [
                "class": String(describing: type(of: window)),
                "title": window.title,
                "sharingType": window.sharingType.rawValue,
                "serverSharingState": server?[kCGWindowSharingState as String] as? Int ?? -1,
            ]
            return entry
        }
    }

    private static func finish(_ report: [String: Any], in directory: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appending(path: "report.json"))
        }
        NSApp.terminate(nil)
    }
}

/// A snapshot run draws views only; it must not read the user's Keychain, which prompts for the
/// login password on every ad-hoc rebuild.
struct NoCredentials: CredentialStoring {
    func read(_ credential: Credential) throws -> Secret? { nil }
    func save(_ secret: Secret, for credential: Credential) throws {}
}

#if DEBUG
/// A calendar source for snapshots: fixed meetings on the days around today.
private struct SampleCalendar: CalendarSource {
    let kind: CalendarSourceKind
    let connection: CalendarConnection

    init(_ kind: CalendarSourceKind, _ connection: CalendarConnection) {
        self.kind = kind
        self.connection = connection
    }

    func status() async -> CalendarConnection { connection }
    func connect() async throws {}
    func disconnect() async {}

    func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let today = Calendar.current.startOfDay(for: Date())
        let live = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 1800).rounded(.down) * 1800 - 900)
        func at(_ day: Int, _ hour: Double, _ minutes: Double, _ title: String, _ calendar: String = "", link: String? = nil,
                allDay: Bool = false) -> CalendarEvent {
            let begin = today.addingTimeInterval(Double(day) * 86_400 + (allDay ? 0 : hour * 3600))
            return CalendarEvent(id: "\(kind)-\(day)-\(hour)-\(title)", title: title, start: begin,
                                 end: begin.addingTimeInterval(allDay ? 86_400 : minutes * 60), isAllDay: allDay,
                                 calendar: calendar, link: link.flatMap(URL.init(string:)), source: kind, uid: "\(day)-\(title)")
        }
        let events: [CalendarEvent] = switch kind {
        case .google: [
            at(0, 9.5, 30, "每日站會", link: "https://meet.google.com/abc-defg-hij"),
            // Around the moment of the snapshot, so a live meeting and its Join button show.
            CalendarEvent(id: "google-live", title: "新款手機行銷策略討論", start: live, end: live.addingTimeInterval(3600),
                          isAllDay: false, calendar: "", link: URL(string: "https://meet.google.com/qrs-tuvw-xyz"), source: .google),
            CalendarEvent(id: "google-next", title: "與 Mei 一對一", start: live.addingTimeInterval(5400), end: live.addingTimeInterval(7200),
                          isAllDay: false, calendar: "", link: URL(string: "https://meet.google.com/jkl-mnop-qrs"), source: .google),
            at(1, 10, 60, "供應商報價會議", link: "https://meet.google.com/xyz-abcd-efg"),
            at(3, 14, 90, "通路合作提案", link: "https://meet.google.com/qrs-tuvw-xyz"),
            at(-2, 11, 60, "直播腳本檢討"),
            at(8, 15, 60, "通路促銷週會", link: "https://meet.google.com/lmn-opqr-stu"),
        ]
        case .apple: [
            at(0, 9.5, 30, "每日站會", "工作"),
            at(0, 11, 60, "Q4 預算審查", "工作", link: "https://teams.microsoft.com/l/meetup-join/sample"),
            at(0, 14, 60, "設計評論", "工作", link: "https://zoom.us/j/5550100"),
            at(1, 0, 0, "產品外訓", "家庭", allDay: true),
            at(5, 13, 45, "牙醫", "家庭"),
            at(-6, 10, 60, "季度規劃", "工作"),
            at(12, 9, 60, "董事會簡報", "工作", link: "https://zoom.us/j/5550101"),
        ]
        case .microsoft: []
        }
        return events.filter { $0.end > start && $0.start < end }
    }
}
#endif
