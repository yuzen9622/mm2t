import AppKit
import MM2TApp
import MM2TLocal
import MM2TProviders
import MM2TSystem
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app: AppController?
    let startupError: String?
    private var floating: FloatingPanelController?
    private var captionBar: CaptionBarController?

    override init() {
        do {
            let signedIn = String(localized: "mm2t is connected. You can close this tab and go back to the app.")
            var defaults = UserDefaults.standard
            var recorder: any Recorder = LiveRecorder()
            var machine = MachineProfile.current
            var fixture = false
            #if DEBUG
            if let isolated = try AssistantScenarioRunner.fixtureDefaults() { defaults = isolated; fixture = true }
            if fixture && UserDefaults.standard.bool(forKey: "MM2TFixtureIntel") {
                machine = MachineProfile(isAppleSilicon: false, memoryBytes: machine.memoryBytes)
            }
            if fixture, let root = AssistantScenarioRunner.fixtureRoot, UserDefaults.standard.bool(forKey: "MM2TReplayAudio") {
                recorder = MeetingAudioReplay(root: root)
                var settings = SettingsStore(defaults: defaults).settings
                settings.transcriptionOrder = [.local]
                settings.localCaptionModel = .nemotron
                settings.localSpeechModel = UserDefaults.standard.bool(forKey: "MM2TReplayBreezeCoreML") ? .breezeCoreML : .breeze
                settings.liveCaptions = true
                settings.captionTranslation = .off
                settings.transcriptionLanguage = .auto
                settings.llmLocation = .local
                SettingsStore(defaults: defaults).settings = settings
            }
            #endif
            app = try AppController.live(defaults: defaults, credentials: Self.credentials, signedInPage: signedIn,
                                         calendars: fixture ? [] : nil, recordingTitle: String(localized: "Recording"),
                                         recorder: recorder, permissions: LivePermissions(), shareWidget: !fixture, machine: machine)
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
        #if DEBUG
        if AssistantScenarioRunner.requested {
            Task { await AssistantScenarioRunner.run(app) }
            return
        }
        #endif
        floating = FloatingPanelController(app: app)
        captionBar = CaptionBarController(app: app)
        if app.collabAccount != nil {
            observeChanges { [weak app] in
                let collaboration = app?.capture.collaboration
                CollabHostPage.shared.prepare(for: collaboration?.room?.hostUrl, retaining: collaboration?.retainedHostURL)
            }
        }
        var fixture = false
        #if DEBUG
        fixture = AssistantScenarioRunner.fixtureRoot != nil
        #endif
        if !fixture { Updates.start() }
        Task { await app.launch(watchMeetings: !fixture) }
        // Opening the app shows its window; without this a launch leaves only the menu bar icon.
        // While setup is unfinished the window shows setup and nothing else.
        WindowOpener.open(WindowID.main)
    }

    /// Opening the app again while it runs (Finder, Dock, `open`) brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { WindowOpener.open(WindowID.main) }
        return true
    }

    /// A desktop widget's Join click arrives as an `mm2t:` link naming an event; the app opens that
    /// event's call. Recording is left to the usual prompt once the call is live.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { app?.widget?.open(url) }
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
