import MM2TApp
import SwiftUI

@main
struct MainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            RootGuard(delegate: delegate) { app in MenuBarContent(app: app) }
                .windowSharingNone()
        } label: {
            MenuBarLabel(app: delegate.app)
        }
        .menuBarExtraStyle(.window)

        Window(Text("mm2t"), id: WindowID.main) {
            RootGuard(delegate: delegate) { app in MainWindow(app: app) }
                .windowSharingNone()
                .regularActivationWhileOpen()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 680)

        Window(Text("Set up mm2t"), id: WindowID.onboarding) {
            RootGuard(delegate: delegate) { app in OnboardingView(app: app) }
                .windowSharingNone()
                .regularActivationWhileOpen()
        }
        .windowResizability(.contentSize)
    }
}

enum WindowID {
    static let main = "main"
    static let onboarding = "onboarding"
}

/// Shows the startup error instead of a view when the data folder could not be opened.
struct RootGuard<Content: View>: View {
    let delegate: AppDelegate
    @ViewBuilder let content: (AppController) -> Content

    var body: some View {
        if let app = delegate.app {
            content(app)
        } else {
            ContentUnavailableView {
                Label("mm2t could not start", systemImage: "exclamationmark.triangle")
            } description: {
                Text(delegate.startupError ?? "")
            }
            .padding()
        }
    }
}
