import AppKit
import MM2TApp
import SwiftUI

/// The borderless panel at the top of the active screen that carries the meeting prompt and the
/// recording island. The island hangs from the screen's top edge and merges with the notch; the
/// panel floats above the menu bar over full-screen apps on every Space and is never captured.
@MainActor
final class FloatingPanelController {
    private let app: AppController
    private let panel: NSPanel
    private let host: NSHostingController<FloatingContent>
    private let banner = JobBanner()
    private let notch = NotchModel()
    /// Room for the widest island plus its tooltips, which hang below it.
    private static let size = NSSize(width: 760, height: 240)

    init(app: AppController) {
        self.app = app
        host = NSHostingController(rootView: FloatingContent(app: app, banner: banner, notch: notch))
        // The panel keeps one fixed, transparent size and the island sits at its top center.
        // Letting the hosting view resize the panel to its content made AppKit and SwiftUI chase
        // each other's sizes once the capsule animated, which crashed the app. Clicks on the
        // transparent area pass through to whatever is underneath.
        host.sizingOptions = []
        panel = TopEdgePanel(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        // Above the menu bar (`.mainMenu`), so the island can cover the notch's strip of it.
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

    /// Story 22: the screen whose menu bar is active, flush with its top edge and centered on the
    /// notch, or on the menu bar where there is none.
    private func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let metrics = NotchMetrics(screen: screen)
        if notch.metrics != metrics { notch.metrics = metrics }
        let size = Self.size
        let origin = NSPoint(x: (metrics.midX ?? screen.frame.midX) - size.width / 2, y: screen.frame.maxY - size.height)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
}

/// A panel AppKit leaves where it is put, even over the menu bar, and that never takes focus.
private final class TopEdgePanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The camera housing at the top of the screen the island merges with.
struct NotchMetrics: Equatable {
    /// The notch's width; zero on a screen without one.
    var width: CGFloat
    /// How far the island reaches down at rest: the notch's height, or the menu bar's.
    var height: CGFloat
    /// The notch's horizontal center in screen coordinates; nil where there is no notch.
    var midX: CGFloat?

    static let none = NotchMetrics(width: 0, height: 24, midX: nil)

    init(width: CGFloat, height: CGFloat, midX: CGFloat? = nil) {
        self.width = width
        self.height = height
        self.midX = midX
    }

    init(screen: NSScreen) {
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            self.init(width: width, height: screen.safeAreaInsets.top, midX: screen.frame.minX + left.width + width / 2)
        } else {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            self.init(width: 0, height: menuBar > 0 ? min(menuBar, 32) : Self.none.height)
        }
    }
}

@MainActor @Observable
final class NotchModel {
    var metrics = NotchMetrics.none
}
