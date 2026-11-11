import AppKit
import ApplicationServices
import CoreAudio
import MM2TCore

/// Reads the raw inputs for `MeetingDetector` from the system. Each source degrades on its own:
///
/// - Mic use (Core Audio process objects): no permission needed.
/// - Frontmost app (NSWorkspace): no permission needed.
/// - Window title (Accessibility API): needs Accessibility; nil without it.
/// - Browser tab URL (Apple Events): needs Automation for that browser; nil without it, and never
///   prompts. Firefox has no scripting URL access, so it relies on the window title.
@MainActor
public enum SystemSignalReader {
    public static func read() -> RawSignals {
        let clients = ((try? AudioProcesses.list()) ?? []).map(\.client)
        let frontmost = NSWorkspace.shared.frontmostApplication
        let bundleID = frontmost?.bundleIdentifier
        return RawSignals(
            clients: clients,
            frontmostBundleID: bundleID,
            frontmostWindowTitle: frontmost.flatMap { focusedWindowTitle(pid: $0.processIdentifier) },
            browserURL: bundleID.flatMap(activeTabURL))
    }

    public static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }

    /// nil for non-browsers, for browsers without a scripting URL, and when Automation is not granted.
    public static func activeTabURL(bundleID: String) -> URL? {
        guard let script = BrowserScripting.activeTabScript(bundleID),
              Permissions.automation(of: bundleID) == .granted else { return nil }
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        return result?.stringValue.flatMap(URL.init(string:))
    }
}

public enum BrowserScripting {
    /// Browsers whose active tab URL is readable over Apple Events. Mirrors the browser list in
    /// `MeetingDetector`, which is not public.
    static let chromium: Set<String> = [
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
    ]

    public static func activeTabScript(_ bundleID: String) -> String? {
        let body: String
        if chromium.contains(bundleID) {
            body = "get URL of active tab of front window"
        } else if bundleID == "com.apple.Safari" {
            body = "get URL of front document"
        } else {
            return nil
        }
        return """
        with timeout of 1 second
            tell application id "\(bundleID)" to \(body)
        end timeout
        """
    }

    public static var scriptableBrowsers: Set<String> { chromium.union(["com.apple.Safari"]) }
}

/// Produces `SystemSignals` on a timer and immediately when any process starts or stops input,
/// so a meeting's end is seen within `releaseGrace` of the app releasing the mic, not a poll later.
@MainActor
public final class SystemSignalMonitor {
    public typealias Handler = @MainActor (SystemSignals, RawSignals) -> Void

    private var assembler: SignalAssembler
    private let interval: TimeInterval
    private var handler: Handler?
    private var timer: Timer?
    private var listListener: PropertyListener?
    private var inputListeners: [AudioObjectID: PropertyListener] = [:]
    private var activation: NSObjectProtocol?

    public init(interval: TimeInterval = 1, releaseGrace: TimeInterval = 3) {
        self.interval = interval
        assembler = SignalAssembler(ownPID: getpid(), releaseGrace: releaseGrace)
    }

    public func start(_ handler: @escaping Handler) {
        self.handler = handler
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        listListener = try? PropertyListener(systemObject, kAudioHardwarePropertyProcessObjectList, queue: .main) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.watchProcesses(); self?.poll() } }
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        watchProcesses()
        poll()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        listListener?.remove()
        inputListeners.values.forEach { $0.remove() }
        inputListeners = [:]
        activation.map(NSWorkspace.shared.notificationCenter.removeObserver)
        handler = nil
    }

    public func poll() {
        guard let handler else { return }
        let raw = SystemSignalReader.read()
        handler(assembler.assemble(raw, now: ProcessInfo.processInfo.systemUptime), raw)
    }

    private func watchProcesses() {
        let objects = Set((try? CoreAudioProperty.array(systemObject, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)) ?? [])
        for gone in Set(inputListeners.keys).subtracting(objects) {
            inputListeners.removeValue(forKey: gone)?.remove()
        }
        for object in objects.subtracting(inputListeners.keys) {
            inputListeners[object] = try? PropertyListener(object, kAudioProcessPropertyIsRunningInput, queue: .main) { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.poll() } }
            }
        }
    }
}
