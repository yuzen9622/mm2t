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
    private static weak var detail: MeetingDetailModel?

    static func mainWindowAppeared(select: @escaping (MeetingID) -> Void) {
        guard isRequested else { return }
        selectMeeting = select
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
            try? await Task.sleep(for: .milliseconds(800))
            save(window(titled: true), to: directory.appending(path: "main-list.png"))
            saveCapsules(to: directory)
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
