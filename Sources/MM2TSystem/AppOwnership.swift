import Foundation

/// What is known about one process when deciding which app it belongs to.
public struct ProcessIdentity: Hashable, Sendable {
    public let pid: pid_t
    /// As Core Audio reports it; a helper reports its own id, e.g. `com.google.Chrome.helper`.
    public let bundleID: String?
    public let executablePath: String?

    public init(pid: pid_t, bundleID: String?, executablePath: String?) {
        self.pid = pid
        self.bundleID = bundleID
        self.executablePath = executablePath
    }
}

/// Resolves helper processes (browser renderers, WebKit's GPU process, Electron helpers) to the
/// app the user sees, which is what `MeetingDetector` and the tap target are keyed by.
public enum AppOwnership {
    /// Order matters: a helper nested inside an app bundle belongs to that bundle; a process living
    /// outside any app (WebKit's XPC services, command-line tools) belongs to the process responsible
    /// for launching it; only then does the process's own bundle id stand.
    public static func owner(
        of process: ProcessIdentity,
        responsible: ProcessIdentity?,
        bundleID bundleIDAtPath: (String) -> String?
    ) -> String? {
        if let app = process.executablePath.flatMap(outermostAppBundle), let id = bundleIDAtPath(app) {
            return id
        }
        if let responsible, responsible.pid != process.pid {
            if let app = responsible.executablePath.flatMap(outermostAppBundle), let id = bundleIDAtPath(app) {
                return id
            }
            if let id = responsible.bundleID { return id }
        }
        return process.bundleID
    }

    /// `/Applications/Google Chrome.app/Contents/Frameworks/.../Helper.app/Contents/MacOS/Helper`
    /// gives `/Applications/Google Chrome.app`.
    public static func outermostAppBundle(in path: String) -> String? {
        guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil)
        else { return nil }
        return String(path[..<range.upperBound]).trimmingSuffix("/")
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
