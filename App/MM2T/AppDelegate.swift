import AppKit
import MM2TApp
import MM2TProviders
import MM2TSystem
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app: AppController?
    let startupError: String?
    private var floating: FloatingPanelController?

    override init() {
        do {
            let signedIn = String(localized: "mm2t is connected. You can close this tab and go back to the app.")
            app = try AppController.live(defaults: .standard, credentials: Self.credentials, signedInPage: signedIn,
                                         recorder: LiveRecorder(), permissions: LivePermissions())
            startupError = nil
        } catch {
            app = nil
            startupError = String(describing: error)
        }
        super.init()
    }

    /// Different debug signatures use a separate service to avoid repeated login keychain prompts.
    private static var credentials: KeychainCredentialStore {
        #if DEBUG
        return KeychainCredentialStore(service: KeychainCredentialStore.defaultService + ".debug")
        #else
        return KeychainCredentialStore()
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowSharing.install(settings: app?.settings)
        guard let app else { return }
        floating = FloatingPanelController(app: app)
        Updates.start()
        Task { await app.launch() }
        // Opening the app shows its window; without this a launch leaves only the menu bar icon.
        WindowOpener.open(WindowID.main)
        // Setup comes first: the main window shows nothing else until it is finished.
        Task {
            await app.enrollment.refresh()
            if app.needsOnboarding { WindowOpener.open(WindowID.onboarding) }
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
