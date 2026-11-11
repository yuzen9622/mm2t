import AppKit
import MM2TApp
import SwiftUI

/// The borderless panel at the top center of the active screen that carries the meeting prompt and
/// the recording capsule. It floats over full-screen apps on every Space and is never captured.
@MainActor
final class FloatingPanelController {
    private let app: AppController
    private let panel: NSPanel
    private let host: NSHostingController<FloatingContent>
    private let banner = JobBanner()
    private static let size = NSSize(width: 760, height: 150)

    init(app: AppController) {
        self.app = app
        host = NSHostingController(rootView: FloatingContent(app: app, banner: banner))
        // The panel keeps one fixed, transparent size and the capsule sits at its top center.
        // Letting the hosting view resize the panel to its content made AppKit and SwiftUI chase
        // each other's sizes once the capsule animated, which crashed the app. Clicks on the
        // transparent area pass through to whatever is underneath.
        host.sizingOptions = []
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentViewController = host
        panel.setContentSize(Self.size)
        WindowSharing.exclude(panel)

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        observeChanges { [weak self] in
            guard let self else { return }
            _ = self.app.queue.revision
            self.banner.update(from: self.app.queue)
        }
        observeChanges { [weak self] in self?.update() }
    }

    private func update() {
        if FloatingContent.isShown(app: app, banner: banner) {
            place()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    /// Story 22: the screen whose menu bar is active, centered under the notch or menu bar.
    private func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = Self.size
        let topInset = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - topInset - size.height + 28)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
}
