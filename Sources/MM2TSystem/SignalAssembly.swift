import Foundation
import MM2TCore

/// One Core Audio client process, already resolved to its owning app.
public struct AudioClient: Hashable, Sendable {
    public let pid: pid_t
    public let ownerBundleID: String?
    public let isRunningInput: Bool
    public let isRunningOutput: Bool

    public init(pid: pid_t, ownerBundleID: String?, isRunningInput: Bool, isRunningOutput: Bool) {
        self.pid = pid
        self.ownerBundleID = ownerBundleID
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

/// Everything the sources read in one poll, before any interpretation.
public struct RawSignals: Hashable, Sendable {
    public var clients: [AudioClient]
    public var frontmostBundleID: String?
    /// nil when Accessibility is not granted or the app has no focused window.
    public var frontmostWindowTitle: String?
    /// nil unless the frontmost app is a browser and Automation for it is granted.
    public var browserURL: URL?

    public init(clients: [AudioClient], frontmostBundleID: String? = nil,
                frontmostWindowTitle: String? = nil, browserURL: URL? = nil) {
        self.clients = clients
        self.frontmostBundleID = frontmostBundleID
        self.frontmostWindowTitle = frontmostWindowTitle
        self.browserURL = browserURL
    }
}

/// Turns raw polls into `SystemSignals`. An app keeps counting as using the mic for `releaseGrace`
/// after its last input IO, because meeting apps briefly stop input when switching devices or
/// rejoining; without the grace the detector would end and immediately re-detect the meeting.
public struct SignalAssembler: Sendable {
    public let ownPID: pid_t
    public let releaseGrace: TimeInterval
    private var lastInput: [String: TimeInterval] = [:]

    public init(ownPID: pid_t, releaseGrace: TimeInterval = 3) {
        self.ownPID = ownPID
        self.releaseGrace = releaseGrace
    }

    /// `now` is any monotonic clock in seconds.
    public mutating func assemble(_ raw: RawSignals, now: TimeInterval) -> SystemSignals {
        for client in raw.clients where client.isRunningInput && client.pid != ownPID {
            if let owner = client.ownerBundleID { lastInput[owner] = now }
        }
        lastInput = lastInput.filter { now - $0.value <= releaseGrace }
        return SystemSignals(
            micBundleIDs: Set(lastInput.keys),
            frontmostBundleID: raw.frontmostBundleID,
            frontmostWindowTitle: raw.frontmostWindowTitle,
            browserURL: raw.browserURL)
    }
}
