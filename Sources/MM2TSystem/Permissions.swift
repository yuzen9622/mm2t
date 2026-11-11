import ApplicationServices
import AVFoundation
import AppKit

public enum PermissionState: String, Sendable, Equatable {
    case granted
    case denied
    /// The user has not been asked yet; requesting will show the system prompt.
    case notDetermined
    /// macOS offers no public way to read this permission.
    case unknown
}

/// The System Settings panes the UI links to when a permission is missing.
public enum SettingsPane: String, Sendable, CaseIterable {
    case microphone = "Privacy_Microphone"
    /// "Screen & System Audio Recording", which holds the system-audio-only list on macOS 14.4+.
    case systemAudio = "Privacy_ScreenCapture"
    case accessibility = "Privacy_Accessibility"
    case automation = "Privacy_Automation"

    public var url: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!
    }
}

/// Reads permission state without prompting. Each `request` call may prompt.
public enum Permissions {
    public static var microphone: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .unknown
        }
    }

    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// System audio capture (TCC `kTCCServiceAudioCapture`) has no public status API. The recorder
    /// reports `RecorderEvent.remoteSilentWhileTargetPlaying` instead, which is how a denial shows up.
    public static var systemAudio: PermissionState { .unknown }

    /// Accessibility has no "not determined" state; untrusted reads as denied.
    public static var accessibility: PermissionState {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Shows the system prompt that adds this app to the Accessibility list.
    public static func requestAccessibility() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Automation (Apple Events) to one app. `.unknown` when that app is not running, since macOS
    /// can only answer for a running target.
    public static func automation(of bundleID: String) -> PermissionState {
        automationStatus(bundleID, ask: false)
    }

    /// Prompts if needed. Blocks until the user answers, so call it off the main thread.
    public static func requestAutomation(of bundleID: String) -> PermissionState {
        automationStatus(bundleID, ask: true)
    }

    private static func automationStatus(_ bundleID: String, ask: Bool) -> PermissionState {
        var target = AEAddressDesc()
        let id = Array(bundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, id, id.count, &target) == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        default: return .unknown
        }
    }
}
