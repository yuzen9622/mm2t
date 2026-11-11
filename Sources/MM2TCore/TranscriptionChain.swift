import Foundation

/// Tries transcription sources in the order settings give (normally self-hosted, cloud, local),
/// falling through only when a source is unreachable.
public struct TranscriptionChain: Sendable {
    public struct Route: Sendable {
        public let source: TranscriptionSource
        public let provider: any TranscriptionProvider
        public init(_ source: TranscriptionSource, _ provider: any TranscriptionProvider) {
            self.source = source
            self.provider = provider
        }
    }

    public let routes: [Route]

    public init(_ routes: [Route]) {
        self.routes = routes
    }

    public func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) async throws -> TrackTranscript {
        var lastError = TranscriptionError.unreachable("no transcription source configured")
        for route in routes {
            do {
                let content = try await route.provider.transcribe(audio: audio, hints: hints, labelSpeakers: labelSpeakers)
                return TrackTranscript(source: route.source, content: content)
            } catch let error as TranscriptionError {
                guard case .unreachable = error else { throw error }
                lastError = error
            }
        }
        throw lastError
    }
}
