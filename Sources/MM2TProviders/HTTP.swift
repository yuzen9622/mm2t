import AVFoundation
import Foundation

struct HTTPResponse {
    let status: Int
    let body: Data
}

extension URLSession {
    /// Connection-level failures become `.unreachable`; any HTTP status is returned for the caller to map.
    func send(_ request: URLRequest, for service: Service) async throws -> HTTPResponse {
        do {
            let (data, response) = try await data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ProviderError(service, .malformedResponse) }
            return HTTPResponse(status: http.statusCode, body: data)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw ProviderError(service, Self.isConnectionFailure(error) ? .unreachable : .serviceError)
        }
    }

    private static func isConnectionFailure(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed,
             .callIsActive, .secureConnectionFailed:
            true
        default:
            false
        }
    }
}

extension HTTPResponse {
    /// The mapping every service shares; each provider overrides the codes it documents differently.
    var commonFailure: ProviderError.Kind {
        switch status {
        case 401: .invalidCredential
        case 402: .outOfCredit
        case 403: .permissionDenied
        case 408, 502, 503, 504: .unavailable
        case 413: .audioTooLarge
        case 429: .rateLimited
        case 400..<500: .rejectedInput
        default: .serviceError
        }
    }
}

struct MultipartForm {
    let boundary = "mm2t-\(UUID().uuidString)"
    private(set) var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func add(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }

    mutating func addFile(_ name: String, filename: String, mimeType: String, data: Data) {
        let safeName = filename.replacingOccurrences(of: "\"", with: "")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(safeName)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.append("\r\n")
    }

    func finished() -> Data {
        var data = body
        data.append("--\(boundary)--\r\n")
        return data
    }
}

private extension Data {
    mutating func append(_ string: String) { append(Data(string.utf8)) }
}

enum AudioFile {
    struct Upload {
        let data: Data
        let filename: String
        let mimeType: String
    }

    /// A WAV is sent as 32 kbps AAC: a 48-minute 16 kHz track drops from 92 MB to about 12 MB,
    /// and upload time, not GPU time, dominated self-hosted runs over a relayed Tailscale link.
    /// Measured on a Mandarin meeting, Breeze-ASR-25's error rate did not change. If encoding
    /// fails the original file is sent unchanged.
    static func upload(_ url: URL, for service: Service) throws -> Upload {
        let original = try read(url, for: service)
        let name = url.deletingPathExtension().lastPathComponent
        if url.pathExtension.lowercased() == "wav", let compressed = try? aac(url) {
            return Upload(data: compressed, filename: "\(name).m4a", mimeType: "audio/mp4")
        }
        return Upload(data: original, filename: url.lastPathComponent, mimeType: mimeType(url))
    }

    static func aac(_ url: URL, bitRate: Int = 32_000) throws -> Data {
        let out = FileManager.default.temporaryDirectory.appending(path: "mm2t-upload-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: out) }
        try encode(url, to: out, bitRate: bitRate)
        return try Data(contentsOf: out)
    }

    /// A separate function so the writer is released, and its file finalized, before the caller reads it.
    private static func encode(_ url: URL, to out: URL, bitRate: Int) throws {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let output = try AVAudioFile(
            forWriting: out,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: bitRate,
            ],
            commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else {
            throw CocoaError(.fileWriteUnknown)
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }

    static func read(_ url: URL, for service: Service) throws -> Data {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            // A WAV that is only its 44-byte header holds no audio; services answer it with a bare 400.
            guard data.count > 44 else { throw ProviderError(service, .audioUnreadable) }
            return data
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError(service, .audioUnreadable)
        }
    }

    static func mimeType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "m4a", "mp4": "audio/mp4"
        case "mp3": "audio/mpeg"
        case "flac": "audio/flac"
        case "caf": "audio/x-caf"
        case "aac": "audio/aac"
        case "ogg", "opus": "audio/ogg"
        default: "application/octet-stream"
        }
    }
}

/// Providers occasionally omit or invert a word's times; the core's `TimeRange` traps on end < start.
func wordRange(_ start: Double?, _ end: Double?, after previousEnd: Double) -> (start: Double, end: Double) {
    let s = max(0, start ?? previousEnd)
    return (s, max(s, end ?? s))
}
