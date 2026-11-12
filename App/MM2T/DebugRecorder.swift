import AppKit
import MM2TApp
import MM2TCore

/// Debug-build footage hook for the promo video. Screen capture is excluded by design, so with
/// `MM2T_RECORD_DIR` set the app renders its own window to JPEG frames in-process, about 30 times a
/// second, while `<dir>/record` exists. That file's first line names the clip; its second line picks
/// the window: `main` (default) or `panel` (the top-edge capsule). Frames are named by milliseconds
/// since the clip started so they can be retimed to a constant frame rate. Writing a bundle ID (or
/// `none`) to `<dir>/signal` feeds capture that app's microphone use, as the meeting monitor would;
/// `record` answers the meeting prompt as its Record button does.
@MainActor
enum DebugRecorder {
    #if DEBUG
    private static let directory = ProcessInfo.processInfo.environment["MM2T_RECORD_DIR"].map { URL(filePath: $0) }
    private static var timer: Timer?
    private static var clip: (name: String, target: String, start: Date)?
    private static var pending = 0
    private static weak var app: AppController?
    private static let writer = DispatchQueue(label: "mm2t.debug-recorder", qos: .userInitiated, attributes: .concurrent)
    #endif

    static func start(app: AppController) {
        #if DEBUG
        guard directory != nil, timer == nil else { return }
        self.app = app
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        #endif
    }

    #if DEBUG
    private static func tick() {
        guard let directory else { return }
        let signal = directory.appending(path: "signal")
        if let bundle = try? String(contentsOf: signal, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
            try? FileManager.default.removeItem(at: signal)
            if bundle == "record" {
                Task { await app?.capture.startPrompted() }
            } else {
                let ids: Set<String> = bundle == "none" ? [] : [bundle]
                Task { await app?.capture.handle(SystemSignals(micBundleIDs: ids)) }
            }
        }
        let control = directory.appending(path: "record")
        guard let request = try? String(contentsOf: control, encoding: .utf8) else {
            clip = nil
            return
        }
        let lines = request.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = lines.first, !name.isEmpty else { return }
        if clip?.name != name {
            clip = (name, lines.count > 1 ? lines[1] : "main", Date())
            try? FileManager.default.createDirectory(at: directory.appending(path: name), withIntermediateDirectories: true)
        }
        guard let clip, pending < 6, let window = target(clip.target), let rep = image(of: window) else { return }
        let millis = Int(Date().timeIntervalSince(clip.start) * 1000)
        let url = directory.appending(path: clip.name).appending(path: String(format: "%07d.jpg", millis))
        pending += 1
        writer.async {
            let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.93])
            try? data?.write(to: url)
            DispatchQueue.main.async { MainActor.assumeIsolated { pending -= 1 } }
        }
    }

    /// The window server's composite of this app's own window when it hands one over (fast, keeps
    /// animations), else the window's view tree drawn in-process.
    private static func image(of window: NSWindow) -> NSBitmapImageRep? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let create = unsafeBitCast(symbol, to: CreateImage.self)
            // including window = 1 << 3; ignore framing = 1 << 0, best resolution = 1 << 3
            if let image = create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue(),
               image.width > 1 {
                return NSBitmapImageRep(cgImage: image)
            }
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private static func target(_ name: String) -> NSWindow? {
        let visible = NSApp.windows.filter(\.isVisible)
        if name == "panel" {
            return visible.filter { $0 is NSPanel && !$0.styleMask.contains(.titled) }.max { $0.frame.width < $1.frame.width }
        }
        return visible.first { $0.styleMask.contains(.titled) && $0.identifier?.rawValue.contains(WindowID.main) == true }
            ?? visible.first { $0.styleMask.contains(.titled) }
    }
    #endif
}
