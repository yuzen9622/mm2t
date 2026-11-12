import AppKit
import MM2TApp
import SwiftUI

/// Story 21: no mm2t window may appear in a screen share or screenshot, unless the user turns off
/// "Hide mm2t from screen sharing and screenshots". Each SwiftUI root applies it as soon as its view
/// joins a window, and these observers catch any window AppKit creates on its own (menu bar panel,
/// sheets, alerts) when it first shows. Changing the setting re-applies it to every open window.
@MainActor
enum WindowSharing {
    /// Follows `AppSettings.hidesFromScreenCapture`; on until the settings are read.
    private(set) static var hides = true {
        didSet { if hides != oldValue { NSApp.windows.forEach(exclude) } }
    }

    static func install(settings: SettingsStore?) {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didUpdateNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NSApp.windows.forEach(exclude) }
            }
        }
        if let settings {
            observeChanges { hides = settings.settings.hidesFromScreenCapture }
        }
        NSApp.windows.forEach(exclude)
    }

    /// Debug-only escape hatch for recording promo footage (`MM2T_ALLOW_CAPTURE=1`): windows stay
    /// capturable and the app uses sample calendars and no stored keys. Release builds always follow the setting.
    #if DEBUG
    static let allowsCapture = ProcessInfo.processInfo.environment["MM2T_ALLOW_CAPTURE"] == "1"
    #else
    static let allowsCapture = false
    #endif

    /// Hides `window` from capture, or makes it capturable again, as the setting says.
    static func exclude(_ window: NSWindow) {
        let type: NSWindow.SharingType = hides && !allowsCapture ? .none : .readOnly
        if window.sharingType != type { window.sharingType = type }
    }
}

private struct WindowSharingGuard: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window.map(WindowSharing.exclude)
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
}

/// Shows the Dock icon and app menu while a main window is open; mm2t is otherwise menu-bar only.
private struct RegularActivation: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
            }
            .onDisappear {
                DispatchQueue.main.async {
                    let open = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
                    if !open { NSApp.setActivationPolicy(.accessory) }
                }
            }
    }
}

extension View {
    func windowSharingNone() -> some View { background(WindowSharingGuard()) }
    func regularActivationWhileOpen() -> some View { modifier(RegularActivation()) }
}

/// Lets AppKit code open SwiftUI windows: the always-present menu bar label registers the action.
@MainActor
enum WindowOpener {
    private static var action: OpenWindowAction?
    private static var pending: [String] = []

    static func register(_ openWindow: OpenWindowAction) {
        action = openWindow
        pending.forEach { openWindow(id: $0) }
        pending = []
    }

    static func open(_ id: String) {
        if let action { action(id: id) } else { pending.append(id) }
        NSApp.activate()
    }
}
