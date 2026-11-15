import Foundation
import MM2TCore

/// ElevenLabs Scribe v2 batch transcription of one track.
/// Docs: https://elevenlabs.io/docs/api-reference/speech-to-text/convert
public struct ElevenLabsScribe: TranscriptionProvider {
    public static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    public static let model = "scribe_v2"
    /// The API accepts 1000, but more than 100 adds a 20 s minimum billable duration.
    public static let maxKeyterms = 100

    let apiKey: Secret
    let languageCode: String?
    let session: URLSession
    let timeout: TimeInterval

    /// `languageCode` is ISO 639-1/3; nil lets Scribe detect it, which suits mixed Mandarin and English.
    public init(apiKey: Secret, languageCode: String? = nil, session: URLSession = .shared, timeout: TimeInterval = 1800) {
        self.apiKey = apiKey
        self.languageCode = languageCode
        self.session = session
        self.timeout = timeout
    }

    public func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) async throws -> TranscribedWords {
        do {
            let upload = try AudioFile.upload(audio, for: .elevenLabs)
            var form = MultipartForm()
            form.add("model_id", Self.model)
            // Diarization only for the remote track; the docs make it exclusive with multichannel,
            // which is why the app sends the two tracks as separate requests.
            form.add("diarize", labelSpeakers ? "true" : "false")
            form.add("tag_audio_events", "false")
            form.add("timestamps_granularity", "word")
            if let languageCode { form.add("language_code", languageCode) }
            for term in Self.keyterms(from: hints) { form.add("keyterms", term) }
            form.addFile("file", filename: upload.filename, mimeType: upload.mimeType, data: upload.data)

            let response = try await session.send(request(form, timeout: timeout), for: .elevenLabs)
            guard response.status == 200 else { throw ProviderError(.elevenLabs, Self.failure(response)) }
            return try Self.parse(response.body, labelSpeakers: labelSpeakers)
        } catch let error as ProviderError {
            throw error.asTranscriptionError
        }
    }

    /// Transcribes half a second of silence: the only check that proves the key exists,
    /// carries the speech-to-text permission and has credit. Costs a negligible amount of audio.
    public func validateKey() async -> KeyCheck {
        var form = MultipartForm()
        form.add("model_id", Self.model)
        form.addFile("file", filename: "silence.wav", mimeType: "audio/wav", data: silentWAV(seconds: 0.5))
        do {
            let response = try await session.send(request(form, timeout: 30), for: .elevenLabs)
            if response.status == 200 { return .valid }
            return .from(ProviderError(.elevenLabs, Self.failure(response)))
        } catch let error as ProviderError {
            return .from(error)
        } catch {
            return .inconclusive(ProviderError(.elevenLabs, .unreachable).description)
        }
    }

    private func request(_ form: MultipartForm, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(apiKey.revealed, forHTTPHeaderField: "xi-api-key")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finished()
        return request
    }

    /// Scribe rejects terms over 50 characters, over 5 words, or containing `<>{}[]\`.
    static func keyterms(from hints: [String]) -> [String] {
        let forbidden = CharacterSet(charactersIn: "<>{}[]\\")
        var seen = Set<String>()
        var terms: [String] = []
        for hint in hints {
            let term = String(hint.unicodeScalars.filter { !forbidden.contains($0) })
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let wordCount = term.split(separator: " ").count
            guard !term.isEmpty, term.count <= 50, wordCount <= 5, seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
            if terms.count == maxKeyterms { break }
        }
        return terms
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable {
            let code: String?
            let status: String?
            let type: String?
        }
        let detail: Detail?
    }

    static func failure(_ response: HTTPResponse) -> ProviderError.Kind {
        let detail = (try? JSONDecoder().decode(ErrorBody.self, from: response.body))?.detail
        let codes = [detail?.code, detail?.status, detail?.type].compactMap { $0 }
        if codes.contains(where: { $0.contains("quota") || $0.contains("credit") }) { return .outOfCredit }
        if codes.contains(where: { $0.contains("concurrent") || $0.contains("rate_limit") || $0 == "system_busy" }) {
            return .rateLimited
        }
        return response.commonFailure
    }

    private struct Response: Decodable {
        struct Word: Decodable {
            let text: String
            /// `word`, `spacing` or `audio_event`.
            let type: String
            let start: Double?
            let end: Double?
            let speakerId: String?
        }
        let words: [Word]
    }

    /// Keeps only `word` tokens: `spacing` carries no text the core needs (it joins CJK without
    /// spaces and Latin with one), and `audio_event` such as "(laughter)" is not speech.
    /// Scribe's token granularity for Mandarin is passed through unchanged; nothing is split or merged.
    static func parse(_ body: Data, labelSpeakers: Bool) throws -> TranscribedWords {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(Response.self, from: body) else {
            throw ProviderError(.elevenLabs, .malformedResponse)
        }
        var labeled: [LabeledWord] = []
        var unlabeled: [TimedWord] = []
        var everyWordLabeled = true
        var previousEnd = 0.0
        for token in response.words where token.type == "word" {
            let text = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let range = wordRange(token.start, token.end, after: previousEnd)
            previousEnd = range.end
            let word = TimedWord(text, range.start, range.end)
            unlabeled.append(word)
            if let speaker = token.speakerId { labeled.append(LabeledWord(word, speaker: ClusterID(speaker))) }
            else { everyWordLabeled = false }
        }
        if labelSpeakers && everyWordLabeled && !labeled.isEmpty {
            return .labeled(labeled.sorted { $0.word.range.start < $1.word.range.start })
        }
        return .unlabeled(unlabeled.sorted { $0.range.start < $1.range.start })
    }
}

func silentWAV(seconds: Double, sampleRate: Int = 16000) -> Data {
    let samples = Int(seconds * Double(sampleRate))
    let dataSize = samples * 2
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
    data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
    data.append(contentsOf: Array("data".utf8)); append(UInt32(dataSize))
    data.append(Data(count: dataSize))
    return data
}
