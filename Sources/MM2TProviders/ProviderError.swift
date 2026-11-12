import Foundation
import MM2TCore

public enum Service: String, Sendable, CaseIterable {
    case elevenLabs
    case selfHosted
    case gemini
    case localTranscription
    case localLLM

    /// User-facing text here is looked up in the app's String Catalog (`Bundle.main`), so it shows in the UI language.
    var displayName: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
        case .selfHosted: String(localized: "the self-hosted transcription server", bundle: .main)
        case .gemini: "Gemini"
        case .localTranscription: String(localized: "the on-device transcription model", bundle: .main)
        case .localLLM: String(localized: "the on-device summary model", bundle: .main)
        }
    }

    var keyName: String {
        switch self {
        case .elevenLabs: "ElevenLabs API Key"
        case .selfHosted: String(localized: "the self-hosted server token", bundle: .main)
        case .gemini: "Gemini API Key"
        case .localTranscription, .localLLM: displayName
        }
    }
}

/// A provider failure in words the user can act on. `description` is the text shown in the UI;
/// it never contains a key, a token, or a raw response body.
public struct ProviderError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public enum Kind: Equatable, Sendable {
        /// No connection: offline, DNS failure, refused, timed out.
        case unreachable
        /// The service answered that it is down or overloaded (502/503/504).
        case unavailable
        case invalidCredential
        case permissionDenied
        case outOfCredit
        case rateLimited
        case rejectedInput
        case audioTooLarge
        case audioUnreadable
        case serviceError
        case malformedResponse
        case blocked
        case meetingTooLong
        /// An on-device model is missing, incomplete, or failed to load.
        case modelUnavailable
    }

    public let service: Service
    public let kind: Kind

    public init(_ service: Service, _ kind: Kind) {
        self.service = service
        self.kind = kind
    }

    /// Whether the transcription chain should move on to the next source.
    public var isFallthrough: Bool { kind == .unreachable || kind == .unavailable }

    public var errorDescription: String? { description }

    public var description: String {
        let name = service.displayName
        let key = service.keyName
        let text = switch kind {
        case .unreachable where service == .selfHosted:
            String(localized: "Couldn't reach \(name). Check that the host is on, on the same local network or Tailscale as this Mac, and that the URL in Settings is correct.", bundle: .main)
        case .unreachable:
            String(localized: "Couldn't reach \(name). Check your internet connection and try again.", bundle: .main)
        case .unavailable:
            String(localized: "\(name) is temporarily unavailable (busy or under maintenance). Try again later.", bundle: .main)
        case .invalidCredential:
            String(localized: "\(key) is invalid or has expired. Enter it again in Settings and save.", bundle: .main)
        case .permissionDenied:
            String(localized: "\(key) isn't allowed to use this feature, or the account or project is restricted. Check the key's permissions and the account status in the \(name) console.", bundle: .main)
        case .outOfCredit:
            String(localized: "Your \(name) account is out of credit. Top up or upgrade your plan in the \(name) console, then try again.", bundle: .main)
        case .rateLimited:
            String(localized: "\(name) reports that a usage or rate limit was reached. Try again later, or check your plan's quota in the \(name) console.", bundle: .main)
        case .rejectedInput:
            String(localized: "\(name) rejected this request. Try again; if it keeps failing, please report it.", bundle: .main)
        case .audioTooLarge:
            String(localized: "The recording is larger than \(name) accepts. Use another transcription source.", bundle: .main)
        case .audioUnreadable:
            String(localized: "\(name) couldn't read this recording. The file may be damaged or silent.", bundle: .main)
        case .serviceError:
            String(localized: "\(name) had an internal error. Try again later.", bundle: .main)
        case .malformedResponse:
            String(localized: "\(name) returned a result in an unexpected format. Try again; if it keeps failing, please report it.", bundle: .main)
        case .blocked:
            String(localized: "\(name) declined to process this meeting under its content safety policy.", bundle: .main)
        case .meetingTooLong:
            String(localized: "This meeting is longer than \(name) can process at once.", bundle: .main)
        case .modelUnavailable:
            String(localized: "\(name) isn't fully downloaded or couldn't load. Download the model again in Settings.", bundle: .main)
        }
        // Service names are lowercase so they read well mid-sentence; a sentence still starts with a capital.
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    package var asTranscriptionError: TranscriptionError {
        isFallthrough ? .unreachable(description) : .failed(description)
    }
}
