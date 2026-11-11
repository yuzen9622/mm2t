import CoreAudio
import Darwin
import AppKit

/// A Core Audio process object (`kAudioProcessClassID`) with its owning app resolved.
public struct AudioProcess: Hashable, Sendable {
    public let objectID: AudioObjectID
    public let identity: ProcessIdentity
    public let ownerBundleID: String?
    public let isRunningInput: Bool
    public let isRunningOutput: Bool

    public var client: AudioClient {
        AudioClient(pid: identity.pid, ownerBundleID: ownerBundleID,
                    isRunningInput: isRunningInput, isRunningOutput: isRunningOutput)
    }
}

/// Reads the process objects Core Audio exposes (macOS 14.2+). Needs no permission.
public enum AudioProcesses {
    public static func list() throws -> [AudioProcess] {
        let objects = try CoreAudioProperty.array(systemObject, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        return objects.compactMap { try? process($0) }
    }

    /// Process objects to tap for `bundleID`: the app itself plus every helper that resolves to it.
    public static func objects(ownedBy bundleID: String) throws -> [AudioObjectID] {
        try list().filter { $0.ownerBundleID == bundleID }.map(\.objectID)
    }

    static func process(_ object: AudioObjectID) throws -> AudioProcess {
        let pid = try CoreAudioProperty.scalar(object, kAudioProcessPropertyPID, as: pid_t.self)
        let identity = ProcessIdentity(
            pid: pid,
            bundleID: (try? CoreAudioProperty.string(object, kAudioProcessPropertyBundleID)).flatMap { $0.isEmpty ? nil : $0 },
            executablePath: executablePath(pid))
        let owner = owner(of: identity)
        return AudioProcess(
            objectID: object,
            identity: identity,
            ownerBundleID: owner,
            isRunningInput: (try? CoreAudioProperty.scalar(object, kAudioProcessPropertyIsRunningInput, as: UInt32.self)) == 1,
            isRunningOutput: (try? CoreAudioProperty.scalar(object, kAudioProcessPropertyIsRunningOutput, as: UInt32.self)) == 1)
    }

    /// The app `pid` belongs to, by the same rules the tap and the mic signal use.
    public static func owner(ofPID pid: pid_t) -> String? {
        owner(of: ProcessIdentity(pid: pid, bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                                  executablePath: executablePath(pid)))
    }

    /// The app bundle TCC holds responsible for `pid`: its prompts name this app and read their
    /// usage strings from its Info.plist. For a command-line tool that is the terminal app.
    public static func responsibleApp(ofPID pid: pid_t) -> URL? {
        let responsible = responsiblePID(pid) ?? pid
        return executablePath(responsible).flatMap(AppOwnership.outermostAppBundle).map { URL(filePath: $0) }
    }

    /// Whether helpers outside any app bundle (WebKit's GPU process) can be attributed at all.
    public static var hasResponsibilityLookup: Bool { responsibilityLookup != nil }

    static func owner(of identity: ProcessIdentity) -> String? {
        let responsible = responsiblePID(identity.pid).flatMap { responsiblePID -> ProcessIdentity? in
            guard responsiblePID != identity.pid else { return nil }
            let app = NSRunningApplication(processIdentifier: responsiblePID)
            return ProcessIdentity(pid: responsiblePID, bundleID: app?.bundleIdentifier, executablePath: executablePath(responsiblePID))
        }
        return AppOwnership.owner(of: identity, responsible: responsible) { Bundle(path: $0)?.bundleIdentifier }
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// The process macOS holds responsible for `pid` (what TCC attributes it to). This is private
    /// libsystem SPI, looked up at runtime so its absence degrades to path-based resolution only.
    /// It is the only way found to tie WebKit's GPU process, which plays and records Safari's
    /// audio from outside Safari.app, back to Safari.
    static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let lookup = responsibilityLookup else { return nil }
        let result = lookup(pid)
        return result > 0 ? result : nil
    }

    private typealias ResponsibilityLookup = @convention(c) (pid_t) -> pid_t
    private static let responsibilityLookup: ResponsibilityLookup? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: ResponsibilityLookup.self)
    }()
}
