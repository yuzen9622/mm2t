import AppKit
import ApplicationServices
import MM2TCore

extension HotkeyModifiers {
    /// The shortcut-relevant part of an event's flags; Caps Lock and the keypad flag are ignored.
    public init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.function) { insert(.function) }
    }
}

/// Watches the keyboard for the record shortcut in every app.
///
/// `RegisterEventHotKey` cannot register modifiers alone or the Fn key, so this reads every
/// modifier change and key press instead: a global monitor for the other apps and a local one for
/// mm2t's own windows, both feeding one `HotkeyDetector`. macOS hands key events to a global monitor
/// only when the app is trusted under Accessibility, which mm2t already asks for to read window
/// titles; until then the shortcut does nothing and nothing prompts. Events are only observed, never
/// consumed, so the keys still reach the app in front.
@MainActor
public final class GlobalHotkeyMonitor {
    /// macOS sends no notification when the Accessibility switch is flipped, so trust is re-read.
    private static let trustInterval: TimeInterval = 2

    private let hotkey: @MainActor () -> Hotkey
    private let fired: @MainActor () -> Void
    private var detector: HotkeyDetector?
    private var monitors: [Any] = []
    private var timer: Timer?
    private var trusted = false

    /// While on, no event reaches the detector: the shortcut field in Settings is taking the keys.
    /// The order in which macOS calls local monitors is not documented, so the field may finish
    /// and lift this before or after this monitor sees the same event. Either way the press is
    /// dropped: the detector restarts from what is held now and ignores that press to its end.
    public var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            detector = isSuspended ? nil : HotkeyDetector(hotkey: hotkey(), held: Self.heldNow)
        }
    }

    private static var heldNow: HotkeyModifiers { HotkeyModifiers(NSEvent.modifierFlags) }

    /// `hotkey` is read on every event, so a changed setting applies from the next key press.
    public init(hotkey: @escaping @MainActor () -> Hotkey, fired: @escaping @MainActor () -> Void) {
        self.hotkey = hotkey
        self.fired = fired
    }

    public func start() {
        refreshTrust()
        timer = Timer.scheduledTimer(withTimeInterval: Self.trustInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTrust() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        removeMonitors()
        trusted = false
    }

    /// Installs the monitors again each time trust is granted: whether one added while untrusted
    /// starts receiving key events once trusted is not documented.
    private func refreshTrust() {
        let now = AXIsProcessTrusted()
        guard now != trusted else { return }
        trusted = now
        removeMonitors()
        guard now else { return }
        detector = HotkeyDetector(hotkey: hotkey(), held: Self.heldNow)
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) { monitors.append(local) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        detector = nil
    }

    private func handle(_ event: NSEvent) {
        guard !isSuspended else { return }
        let current = hotkey()
        // A press under way when the shortcut changed is ignored to its end, like one on resume.
        if detector?.hotkey != current { detector = HotkeyDetector(hotkey: current, held: Self.heldNow) }
        let modifiers = HotkeyModifiers(event.modifierFlags)
        let didFire = switch event.type {
        case .flagsChanged: detector?.modifiersChanged(modifiers) ?? false
        case .keyDown: detector?.keyDown(event.keyCode, modifiers: modifiers, isRepeat: event.isARepeat) ?? false
        default: false
        }
        if didFire { fired() }
    }
}
