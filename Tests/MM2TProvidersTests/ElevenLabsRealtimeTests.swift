import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TProviders

/// Message shapes follow the realtime API reference and event reference (read 2026-11-16).
@Suite struct ElevenLabsRealtimeTests {
    @Test func connectsWithTheDocumentedQuery() throws {
        let url = ElevenLabsRealtime.url(for: StreamingTranscriptionRequest(
            languageCode: "zh", hints: ["王小明", "Kubernetes", "a very long product name over twenty"], sampleRate: 16_000))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "wss")
        #expect(components.host == "api.elevenlabs.io")
        #expect(components.path == "/v1/speech-to-text/realtime")
        let items = components.queryItems ?? []
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }
        #expect(values("model_id") == ["scribe_v3_live"])
        #expect(values("audio_format") == ["pcm_16000"])
        #expect(values("commit_strategy") == ["vad"])
        #expect(values("language_code") == ["zh"])
        #expect(values("keepalive_interval_ms") == ["5000"])
        // Realtime keyterms are at most 20 characters; the long one is dropped, not cut.
        #expect(values("keyterms") == ["王小明", "Kubernetes"])
    }

    @Test func autoLanguageAndNoHintsSendNeither() throws {
        let url = ElevenLabsRealtime.url(for: StreamingTranscriptionRequest(languageCode: nil, hints: [], sampleRate: 16_000))
        let names = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        #expect(!names.contains("language_code"))
        #expect(!names.contains("keyterms"))
    }

    @Test func realtimeKeytermsStopAtFifty() {
        let hints = (0..<80).map { "term\($0)" }
        let url = ElevenLabsRealtime.url(for: StreamingTranscriptionRequest(languageCode: nil, hints: hints, sampleRate: 16_000))
        let terms = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "keyterms" } ?? []
        #expect(terms.count == 50)
    }

    @Test func audioIsLittleEndianPCMInTheDocumentedChunk() throws {
        let text = ElevenLabsRealtime.audioMessage([0, 1, -1, 2, .nan], sampleRate: 16_000)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["message_type"] as? String == "input_audio_chunk")
        #expect(object["commit"] as? Bool == false)
        #expect(object["sample_rate"] as? Int == 16_000)
        #expect(object["previous_text"] == nil)
        let audio = try #require(object["audio_base_64"] as? String)
        let pcm = try #require(Data(base64Encoded: audio))
        #expect([UInt8](pcm) == [0x00, 0x00, 0xFF, 0x7F, 0x01, 0x80, 0xFF, 0x7F, 0x00, 0x00])
    }

    @Test func previousTextRidesOnlyTheFirstChunk() throws {
        let text = ElevenLabsRealtime.audioMessage([0], sampleRate: 16_000, previousText: "上一句")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["previous_text"] as? String == "上一句")
    }

    @Test func decodesTheDocumentedMessages() {
        let started = #"{"message_type":"session_started","session_id":"abc","config":{"sample_rate":16000,"audio_format":"pcm_16000","model_id":"scribe_v3_live","commit_strategy":"vad"}}"#
        #expect(ElevenLabsRealtime.decode(Data(started.utf8)) == .sessionStarted)
        let partial = #"{"message_type":"partial_transcript","text":"My phone number is 415","turn_probability":0.08}"#
        #expect(ElevenLabsRealtime.decode(Data(partial.utf8)) == .transcript(.partial("My phone number is 415")))
        let keepalive = #"{"message_type":"partial_transcript","text":""}"#
        #expect(ElevenLabsRealtime.decode(Data(keepalive.utf8)) == .transcript(.partial("")))
        let committed = #"{"message_type":"committed_transcript","text":"大家好，今天討論預算。"}"#
        #expect(ElevenLabsRealtime.decode(Data(committed.utf8)) == .transcript(.final("大家好，今天討論預算。")))
        let timestamps = #"{"message_type":"committed_transcript_with_timestamps","text":"hi","language_code":"en","words":[]}"#
        #expect(ElevenLabsRealtime.decode(Data(timestamps.utf8)) == .ignored)
        let warning = #"{"message_type":"warning","warning":"slow down"}"#
        #expect(ElevenLabsRealtime.decode(Data(warning.utf8)) == .ignored)
    }

    @Test func errorsThatNeedTheUserStopWhileOthersAreRetried() {
        func decoded(_ type: String) -> ElevenLabsRealtime.Message {
            ElevenLabsRealtime.decode(Data(#"{"message_type":"\#(type)","error":"details"}"#.utf8))
        }
        #expect(decoded("auth_error") == .failure(.failed(ProviderError(.elevenLabs, .invalidCredential).description)))
        #expect(decoded("quota_exceeded") == .failure(.failed(ProviderError(.elevenLabs, .outOfCredit).description)))
        #expect(decoded("unaccepted_terms") == .failure(.failed(ProviderError(.elevenLabs, .permissionDenied).description)))
        #expect(decoded("input_error") == .failure(.failed(ProviderError(.elevenLabs, .rejectedInput).description)))
        for type in ["rate_limited", "queue_overflow", "resource_exhausted", "commit_throttled"] {
            #expect(decoded(type) == .failure(.unreachable(ProviderError(.elevenLabs, .unavailable).description)))
        }
        for type in ["error", "transcriber_error", "session_time_limit_exceeded", "insufficient_audio_activity"] {
            #expect(decoded(type) == .failure(.unreachable(ProviderError(.elevenLabs, .unreachable).description)))
        }
        #expect(ElevenLabsRealtime.decode(Data("not json".utf8))
            == .failure(.failed(ProviderError(.elevenLabs, .malformedResponse).description)))
    }

    @Test func aRefusedUpgradeMapsItsStatus() {
        let response = HTTPURLResponse(url: ElevenLabsRealtime.endpoint, statusCode: 401, httpVersion: nil, headerFields: nil)
        let error = ElevenLabsRealtime.transcriptionError(URLError(.badServerResponse), response: response)
        #expect(error as? TranscriptionError == .failed(ProviderError(.elevenLabs, .invalidCredential).description))
        let dropped = ElevenLabsRealtime.transcriptionError(URLError(.networkConnectionLost), response: nil)
        #expect(dropped as? TranscriptionError == .unreachable(ProviderError(.elevenLabs, .unreachable).description))
    }
}
