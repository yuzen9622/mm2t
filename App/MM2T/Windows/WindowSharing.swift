import AppKit
import SwiftUI

/// Story 21: no mm2t window may appear in a screen share or screenshot. Each SwiftUI root sets it
/// as soon as its view joins a window, and these observers catch any window AppKit creates on its
/// own (menu bar panel, sheets, alerts) when it first shows.
@MainActor
enum WindowSharing {
    static func install() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didUpdateNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NSApp.windows.forEach(exclude) }
            }
        }
        NSApp.windows.forEach(exclude)
    }

    static func exclude(_ window: NSWindow) {
        if window.sharingType != .none { window.sharingType = .none }
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
