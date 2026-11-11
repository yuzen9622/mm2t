import Foundation
import MM2TCore

public enum Service: String, Sendable, CaseIterable {
    case elevenLabs
    case selfHosted
    case gemini

    var displayName: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
        case .selfHosted: "自架轉錄伺服器"
        case .gemini: "Gemini"
        }
    }

    var keyName: String {
        switch self {
        case .elevenLabs: "ElevenLabs API Key"
        case .selfHosted: "自架伺服器 Token"
        case .gemini: "Gemini API Key"
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
        switch kind {
        case .unreachable:
            return service == .selfHosted
                ? "無法連線到\(name)。請確認主機已開機、與這台 Mac 在同一個區網或 Tailscale，以及設定中的網址正確。"
                : "無法連線到 \(name)。請確認網路連線後重試。"
        case .unavailable:
            return "\(name) 暫時無法服務（忙碌或維護中），請稍後重試。"
        case .invalidCredential:
            return "\(service.keyName) 無效或已過期。請到設定重新填入並按「驗證」。"
        case .permissionDenied:
            return "\(service.keyName) 沒有這項功能的權限，或帳號／專案受到限制。請到 \(name) 後台檢查 Key 的權限與帳號狀態。"
        case .outOfCredit:
            return "\(name) 帳號額度不足。請到 \(name) 後台儲值或升級方案後重試。"
        case .rateLimited:
            return "\(name) 回報已達用量或速率上限。請稍後重試，或到 \(name) 後台檢查方案額度。"
        case .rejectedInput:
            return "\(name) 拒絕了這次請求的內容。請重試；若一直失敗，請回報這個問題。"
        case .audioTooLarge:
            return "錄音檔超過 \(name) 允許的大小上限。請改用其他轉錄來源。"
        case .audioUnreadable:
            return "\(name) 無法讀取這段錄音。錄音檔可能已損毀或沒有聲音。"
        case .serviceError:
            return "\(name) 處理時發生內部錯誤。請稍後重試。"
        case .malformedResponse:
            return "\(name) 回傳的結果格式不正確。請重試；若一直失敗，請回報這個問題。"
        case .blocked:
            return "\(name) 因內容安全政策拒絕處理這場會議。"
        case .meetingTooLong:
            return "這場會議太長，超過 \(name) 單次能處理的上限。"
        }
    }

    var asTranscriptionError: TranscriptionError {
        isFallthrough ? .unreachable(description) : .failed(description)
    }
}
