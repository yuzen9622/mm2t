import AppKit
import MM2TApp
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app: AppController?
    let startupError: String?
    private var floating: FloatingPanelController?

    override init() {
        do {
            app = try DebugSnapshot.isRequested ? AppController.live(credentials: NoCredentials()) : AppController.live()
            startupError = nil
        } catch {
            app = nil
            startupError = String(describing: error)
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowSharing.install()
        guard let app else { return }
        floating = FloatingPanelController(app: app)
        #if DEBUG
        if DebugSnapshot.isRequested {
            Task { await app.launch(watchMeetings: false) }
            DebugSnapshot.run(app: app)
            return
        }
        #endif
        #if DEBUG
        if DebugBenchmark.isRequested {
            Task { await app.launch(watchMeetings: false) }
            DebugBenchmark.run(app: app)
            return
        }
        #endif
        Updates.start()
        Task { await app.launch() }
        // Opening the app shows its window; without this a launch leaves only the menu bar icon.
        WindowOpener.open(WindowID.main)
        // The setup window introduces itself once. After that everything in it lives in Settings.
        if !app.settings.settings.hasCompletedOnboarding {
            app.settings.settings.hasCompletedOnboarding = true
            WindowOpener.open(WindowID.onboarding)
        }
    }

    /// Opening the app again while it runs (Finder, Dock, `open`) brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { WindowOpener.open(WindowID.main) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        app?.setup.refresh()
    }
}

/// Calls `apply` now and again whenever an observable property it read changes.
@MainActor
func observeChanges(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking(apply) {
        Task { @MainActor in observeChanges(apply) }
    }
}
