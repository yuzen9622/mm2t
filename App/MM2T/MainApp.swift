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
        // The window follows its content's size limits: fixed while setup shows, at least the
        // app's minimum otherwise. `MainWindow` sets those limits and animates the frame between them.
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
            CommandGroup(after: .undoRedo) {
                Button("Undo move") { delegate.app?.folders.undo() }
                    .disabled(delegate.app?.folders.canUndo != true)
            }
            CommandGroup(after: .textEditing) {
                Button("Search…") { MainNavigation.shared.searchOpen.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(delegate.app?.showsSetup ?? true)
            }
        }
    }
}

enum WindowID {
    static let main = "main"
}

/// Shows the startup error instead of a view when the data folder could not be opened.
struct RootGuard<Content: View>: View {
    let delegate: AppDelegate
    @ViewBuilder let content: (AppController) -> Content

    var body: some View {
        if let app = delegate.app {
            content(app).liveLanguage()
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
