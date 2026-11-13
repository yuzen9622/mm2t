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
            await saveHomeTips(app: app, to: directory)
            await saveHomeVariants(app: app, to: directory)
            for (section, name) in [(SidebarItem.vocabulary, "vocabulary"), (.people, "people"), (.meetings, "list")] {
                showSection?(section)
                try? await Task.sleep(for: .milliseconds(900))
                save(window(titled: true), to: directory.appending(path: "main-\(name).png"))
                if section == .vocabulary { await saveVocabularyEdits(app: app, to: directory) }
            }
            await saveScrolledList(to: directory)
            await saveSettings(app: app, to: directory)
            saveCapsules(to: directory)
            await saveIslands(to: directory)
            await saveMenus(app: app, to: directory)
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
            await saveMenu(MenuBarContent(app: app), to: directory.appending(path: "menubar-prompting.png"))
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

    /// The dashboard with one tooltip showing at a time: over the month's paging buttons at the top
    /// of the calendar card, and over a heatmap cell among its neighbours.
    private static func saveHomeTips(app: AppController, to directory: URL) async {
        #if DEBUG
        let stage = SnapshotStage.shared
        var tips: [(String, Text)] = [("calendar", Text("Previous Month")), ("calendar-next", Text("Next Month"))]
        let days = app.dashboard.activity
        if let day = days.dropFirst(days.count / 2).first(where: { $0.minutes > 0 }) ?? days.dropFirst(days.count / 2).first {
            tips.append(("heatmap", Text(verbatim: day.tipLabel)))
        }
        if let last = days.last { tips.append(("heatmap-last", Text(verbatim: last.tipLabel))) }
        for (name, tip) in tips {
            stage.tip = tip
            try? await Task.sleep(for: .milliseconds(700))
            save(window(titled: true), to: directory.appending(path: "main-home-tip-\(name).png"))
        }
        stage.tip = nil
        #endif
    }

    /// The settings dialog over the main window on each section, a search across sections, and
    /// every section drawn at full length (the dialog scrolls). Key rows show their checked state.
    private static func saveSettings(app: AppController, to directory: URL) async {
        #if DEBUG
        let navigation = MainNavigation.shared
        let stage = SnapshotStage.shared
        stage.keysVerified = true
        navigation.settingsSection = .general
        navigation.settingsOpen = true
        try? await Task.sleep(for: .milliseconds(1200))
        for section in SettingsSection.allCases {
            navigation.settingsSection = section
            try? await Task.sleep(for: .milliseconds(900))
            save(window(titled: true), to: directory.appending(path: "settings-\(section.rawValue).png"))
        }
        stage.settingsQuery = "Gemini"
        try? await Task.sleep(for: .milliseconds(700))
        save(window(titled: true), to: directory.appending(path: "settings-search.png"))
        stage.settingsQuery = nil
        // The language switched while the dialog is open: every string in it, the calendar rows
        // included, must follow at once.
        let language = AppLanguage.current(in: .standard, domain: Bundle.main.bundleIdentifier ?? "dev.mm2t.app")
        let chinese = LiveLanguage.shared.locale.identifier.hasPrefix("zh")
        navigation.settingsSection = .permissions
        LiveLanguage.shared.apply(chinese ? .english : .traditionalChinese, persist: false)
        try? await Task.sleep(for: .milliseconds(1200))
        save(window(titled: true), to: directory.appending(path: "settings-permissions-switched.png"))
        LiveLanguage.shared.apply(language, persist: false)
        try? await Task.sleep(for: .milliseconds(900))
        navigation.settingsOpen = false
        try? await Task.sleep(for: .milliseconds(600))
        for section in SettingsSection.allCases {
            render(SettingsPage(app: app, section: section, query: "", showLicenses: .constant(false))
                .frame(width: 560).padding(24).background(Palette.window).foregroundStyle(Palette.text).font(Typo.body),
                   to: directory.appending(path: "settings-\(section.rawValue)-full.png"))
        }
        stage.keysVerified = false
        #endif
    }

    /// The meeting list scrolled part way, where both edges fade, and to its end, where only the top does.
    private static func saveScrolledList(to directory: URL) async {
        #if DEBUG
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        guard let root = window(titled: true)?.contentView,
              let list = scrollViews(in: root).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        else { return }
        list.contentView.scroll(to: NSPoint(x: 0, y: 170))
        list.reflectScrolledClipView(list.contentView)
        try? await Task.sleep(for: .milliseconds(600))
        save(window(titled: true), to: directory.appending(path: "main-list-scrolled.png"))
        if let document = list.documentView {
            list.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - list.contentView.bounds.height)))
            list.reflectScrolledClipView(list.contentView)
            try? await Task.sleep(for: .milliseconds(600))
            save(window(titled: true), to: directory.appending(path: "main-list-end.png"))
        }
        list.contentView.scroll(to: .zero)
        list.reflectScrolledClipView(list.contentView)
        #endif
    }

    /// A vocabulary term being edited: once with a new spelling, once refused as a duplicate.
    private static func saveVocabularyEdits(app: AppController, to directory: URL) async {
        #if DEBUG
        let terms = app.settings.settings.vocabulary
        guard let term = terms.last else { return }
        let stage = SnapshotStage.shared
        for (name, draft) in [("edit", term + " 2"), ("edit-duplicate", terms.count > 1 ? terms[0].uppercased() : term + ",")] {
            stage.editingTerm = .init(term: term, draft: draft)
            try? await Task.sleep(for: .milliseconds(700))
            save(window(titled: true), to: directory.appending(path: "main-vocabulary-\(name).png"))
            stage.editingTerm = nil
            try? await Task.sleep(for: .milliseconds(300))
        }
        #endif
    }

    /// The notch island at rest and opened, under a MacBook notch and on a screen without one.
    private static func saveIslands(to directory: URL) async {
        #if DEBUG
        let speech = [0.9, 0.7, 0.95, 0.6, 0.8, 0.5]
        let notch = NotchMetrics(width: 185, height: 32)
        func island(_ metrics: NotchMetrics, open: Bool, @ViewBuilder _ content: () -> some View,
                    leading: some View = RecordingDot(), trailing: some View = MiniMeter(level: 0.8)) -> some View {
            VStack(spacing: 0) {
                NotchIsland(metrics: metrics, stays: false, forcesOpen: open, expanded: content, leading: { leading }, trailing: { trailing })
                Spacer(minLength: 0)
            }
            .frame(width: 720, height: open ? 150 : 50)
            .background(alignment: .top) {
                // The menu bar strip, so the island's top corners read against it.
                LinearGradient(colors: [Color(white: 0.82), Color(white: 0.7)], startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .top) {
                // Where the physical notch is, outlined so the merge can be judged.
                if metrics.width > 0 {
                    UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
                        .stroke(.red.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: metrics.width, height: metrics.height)
                }
            }
            .tipLayer(prefersBelow: true)
        }
        func bar(paused: Bool = false) -> some View {
            CapsuleBar(isPaused: paused, level: 0.8, elapsed: 768, remoteSilent: false, showsHighlight: true,
                       hasHighlights: false, toggle: {}, highlight: {}, finish: {})
                .environment(\.snapshotWaveform, speech)
        }
        let view = VStack(spacing: 10) {
            island(notch, open: false) { bar() }
            // Starting, saving, and processing have only a leading spinner. An empty trailing
            // wing must still reserve its width or the spinner drifts under the physical notch.
            island(notch, open: false, { Working(text: "Transcribing") }, leading: Spinner(), trailing: EmptyView())
            island(notch, open: false, { bar(paused: true) }, leading: Icon("player-pause-filled", size: 13).foregroundStyle(Palette.orange),
                   trailing: MiniMeter(level: nil))
            island(notch, open: true) { bar() }
            island(notch, open: true) {
                EndingSoon(deadline: Date().addingTimeInterval(4.9), keep: {}, stop: {})
            }
            island(notch, open: true) {
                HStack(spacing: 10) {
                    Status(icon: "video", text: "\("Zoom") meeting")
                    CapsulePill("Record", filled: true) {}
                    CircleButton("Not This Time", icon: "x") {}
                }
            }
            island(notch, open: true) { Working(text: "Transcribing") }
            island(.none, open: false) { bar() }
            island(.none, open: false, { Working(text: "Transcribing") }, leading: Spinner(), trailing: EmptyView())
            island(.none, open: true) { bar() }
        }
        .padding(16)
        .background(Color(white: 0.3))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let the islands measure their open content and settle their spring.
        try? await Task.sleep(for: .milliseconds(1200))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "islands.png"))
        #endif
    }

    /// The menu bar window in each capture state, drawn with fixed meters, in light and dark.
    private static func saveMenus(app: AppController, to directory: URL) async {
        #if DEBUG
        let target = RecordingTarget(bundleID: "us.zoom.xos", name: "Zoom", platform: .zoom)
        let meters = MeterReading(me: 0.72, remote: 0.45, elapsed: 1_528, highlights: 2, remoteSilent: false)
        let states: [(String, CaptureState)] = [
            ("idle", .idle), ("recording", .recording(target)), ("paused", .paused(target)),
            ("endingSoon", .endingSoon(target, deadline: Date().addingTimeInterval(4.9))),
            ("failed", .failed(.microphoneDenied)),
        ]
        for (name, state) in states {
            await saveMenu(MenuBarContent(app: app, preview: (state, meters)), to: directory.appending(path: "menubar-\(name).png"))
        }
        await saveMenu(MenuBarContent(app: app, preview: (.idle, meters), previewSetUp: true), to: directory.appending(path: "menubar-idle-ready.png"))
        await saveMenu(MenuBarContent(app: app, preview: (.idle, meters)), dark: true, to: directory.appending(path: "menubar-idle-dark.png"))
        await saveMenu(MenuBarContent(app: app, preview: (.recording(target), meters)), dark: true,
                       to: directory.appending(path: "menubar-recording-dark.png"))
        #endif
    }

    private static func saveMenu(_ view: MenuBarContent, dark: Bool = false, to url: URL) async {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        // Let the calendar load and the reveal animations settle before drawing.
        try? await Task.sleep(for: .milliseconds(900))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        window.setContentSize(host.frame.size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Calendar sources with fixed events around today, so the dashboard's calendar can be judged
    /// without signing in anywhere. Outlook stays unavailable, as in a build without its client ID.
    static var sampleCalendars: [any CalendarSource]? {
        #if DEBUG
        guard isRequested || WindowSharing.allowsCapture else { return nil }
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
        main.setContentSize(NSSize(width: 1440, height: 900))
        try? await Task.sleep(for: .milliseconds(900))
        save(main, to: directory.appending(path: "main-home-wide.png"))
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
        render(VStack(alignment: .leading, spacing: 14) {
            VoiceprintSummary(count: 4, channels: [.room, .call])
            VoiceprintSummary(count: 2, channels: [.room])
            VoiceprintSummary(count: 3, channels: [.call])
            VoiceprintSummary(count: 0, channels: [])
        }.frame(width: 420, alignment: .leading).padding(16).background(Palette.card), to: directory.appending(path: "people-channels.png"))
        let words = ["XD", "可以", "Google", "一個", "應該", "現在", "沒有", "什麼", "Galaxy", "這樣", "Nexus", "Samsung", "還有",
                     "不過", "就是", "早安", "測試", "Android", "分享", "這是", "HTC", "東西", "影片", "Blogger", "ROM", "哈哈",
                     "今天", "我想", "如果", "好笑", "心情", "墾丁", "watch", "公車", "朋友", "準備", "鍵盤", "台中", "上班", "環島"]
        let terms = words.enumerated().map { TermRow(term: $1, count: max(1, 60 / ($0 + 1) + (words.count - $0) / 4)) }
        for (name, width) in [("wordcloud", 520.0), ("wordcloud-narrow", 360.0)] {
            render(WordCloud(terms: terms, revealed: true).frame(width: width).padding(16).background(Palette.card),
                   to: directory.appending(path: "\(name).png"))
        }
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
        .tipLayer()
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
                Status(icon: "video", text: "\("Zoom") meeting")
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

/// What a snapshot run asks views to show that normally needs the pointer or the keyboard. Both
/// stay nil outside a snapshot run.
@MainActor @Observable
final class SnapshotStage {
    struct Editing: Equatable {
        let term: String
        let draft: String
    }

    static let shared = SnapshotStage()
    /// Tooltips with this text show as if hovered.
    var tip: Text?
    /// The vocabulary term that opens for editing, with this text typed.
    var editingTerm: Editing?
    /// Typed into the settings dialog's search field.
    var settingsQuery: String?
    /// Key rows show the check mark of a key that passed its check.
    var keysVerified = false
}

/// A snapshot run draws views only; it must not read the user's Keychain, which prompts for the
/// login password on every ad-hoc rebuild.
struct NoCredentials: CredentialStoring {
    func read(_ credential: Credential) throws -> Secret? { nil }
    func save(_ secret: Secret, for credential: Credential) throws {}
}

#if DEBUG
/// Sample event titles follow the app's language, so English captures show English events.
private func sample(_ zh: String, _ en: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en
}

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
            at(0, 9.5, 30, sample("每日站會", "Daily standup"), link: "https://meet.google.com/abc-defg-hij"),
            // Around the moment of the snapshot, so a live meeting and its Join button show.
            CalendarEvent(id: "google-live", title: sample("新款手機行銷策略討論", "Remote control kickoff"), start: live, end: live.addingTimeInterval(3600),
                          isAllDay: false, calendar: "", link: URL(string: "https://meet.google.com/qrs-tuvw-xyz"), source: .google),
            CalendarEvent(id: "google-next", title: sample("與 Mei 一對一", "1:1 with Mei"), start: live.addingTimeInterval(5400), end: live.addingTimeInterval(7200),
                          isAllDay: false, calendar: "", link: URL(string: "https://meet.google.com/jkl-mnop-qrs"), source: .google),
            at(1, 10, 60, sample("供應商報價會議", "Vendor pricing call"), link: "https://meet.google.com/xyz-abcd-efg"),
            at(3, 14, 90, sample("通路合作提案", "Channel partner pitch"), link: "https://meet.google.com/qrs-tuvw-xyz"),
            at(-2, 11, 60, sample("直播腳本檢討", "Livestream script review")),
            at(8, 15, 60, sample("通路促銷週會", "Weekly promo sync"), link: "https://meet.google.com/lmn-opqr-stu"),
        ]
        case .apple: [
            at(0, 9.5, 30, sample("每日站會", "Daily standup"), sample("工作", "Work")),
            at(0, 11, 60, sample("Q4 預算審查", "Q4 budget review"), sample("工作", "Work"), link: "https://teams.microsoft.com/l/meetup-join/sample"),
            at(0, 14, 60, sample("設計評論", "Design critique"), sample("工作", "Work"), link: "https://zoom.us/j/5550100"),
            at(1, 0, 0, sample("產品外訓", "Product offsite"), sample("家庭", "Family"), allDay: true),
            at(5, 13, 45, sample("牙醫", "Dentist"), sample("家庭", "Family")),
            at(-6, 10, 60, sample("季度規劃", "Quarterly planning"), sample("工作", "Work")),
            at(12, 9, 60, sample("董事會簡報", "Board briefing"), sample("工作", "Work"), link: "https://zoom.us/j/5550101"),
        ]
        case .microsoft: []
        }
        return events.filter { $0.end > start && $0.start < end }
    }
}
#endif
