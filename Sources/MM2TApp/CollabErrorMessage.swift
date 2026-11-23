import Foundation
import MM2TProviders

extension CollabError {
    public var collabMessage: String {
        switch self {
        case .notSignedIn: String(localized: "Sign in to share")
        case .quotaExceeded(let used, let limit): String(localized: "Room limit reached (\(used)/\(limit)).")
        case .planRequired: String(localized: "Hosting a room needs a Standard or Pro plan.")
        case .roomEnded: String(localized: "This room has ended.")
        case .pendingEndPersistence: String(localized: "Couldn’t save the pending collaboration room closure.")
        case .credentialCleanup: String(localized: "Couldn’t remove the saved collaboration sign-in.")
        case .unreachable: String(localized: "Can’t connect to the collaboration service.")
        case .invalidBatch, .server: String(localized: "The collaboration service couldn’t complete the request.")
        }
    }
}
