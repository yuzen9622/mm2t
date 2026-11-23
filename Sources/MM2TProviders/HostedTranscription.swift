import AVFoundation
import Foundation
import MM2TCore

/// mm2t plan transcription. The backend meters by lease: one per meeting, opened before the first
/// piece and finished after both tracks. Each track goes up in pieces of at most 110 seconds that
/// start on whole seconds, and the backend charges each piece once, at its longest track.
public struct HostedTranscription: TranscriptionProvider {
    /// `…/v1/hosted/stt`.
    let baseURL: URL
    let authorization: HostedAuthorization
    let languageCode: String?
    let leases: HostedLeases
    let session: URLSession
    let pieceSeconds: Int
    let parallelPieces: Int
    let timeout: TimeInterval

    public init(baseURL: URL, authorization: HostedAuthorization, languageCode: String? = nil, leases: HostedLeases,
                session: URLSession = .shared, pieceSeconds: Int = 110, parallelPieces: Int = 3, timeout: TimeInterval = 600) {
        self.baseURL = baseURL
        self.authorization = authorization
        self.languageCode = languageCode
        self.leases = leases
        self.session = session
        self.pieceSeconds = pieceSeconds
        self.parallelPieces = max(1, parallelPieces)
        self.timeout = timeout
    }

    package static func validateKey(baseURL: URL, authorization: HostedAuthorization, session: URLSession) async -> KeyCheck {
        do {
            let response = try await authorization.send(session) { token in
                var request = URLRequest(url: baseURL.appending(path: "v1/transcriptions"), timeoutInterval: 30)
                request.httpMethod = "GET"
                request.setValue("Bearer \(token.revealed)", forHTTPHeaderField: "Authorization")
                return request
            }
            if response.status == 405 || (200..<300).contains(response.status) { return .valid }
            return .from(ProviderError(.mm2tPlan, response.hostedFailure))
        } catch let error as ProviderError {
            return .from(error)
        } catch {
            return .inconclusive(ProviderError(.mm2tPlan, .unreachable).description)
        }
    }

    public func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) async throws -> TranscribedWords {
        // Outside a meeting (voiceprint enrollment) the lease covers this one file.
        let context = TranscriptionContext.current
        let key = context?.meeting ?? "single-\(UUID().uuidString)"
        do {
            let words = try await leases.withUse(of: key) {
                try await transcribe(audio, key: key, track: context?.track ?? .me, hints: hints)
            }
            if context == nil { await finishSession(meeting: key) }
            return .unlabeled(words)
        } catch let error as ProviderError {
            if context == nil { await finishSession(meeting: key) }
            throw error.asTranscriptionError
        } catch {
            if context == nil { await finishSession(meeting: key) }
            throw error
        }
    }

    public func finishSession(meeting: String) async {
        guard let id = await leases.end(meeting) else { return }
        await finish(id)
    }

    // MARK: Pieces

    private func transcribe(_ audio: URL, key: String, track: Track, hints: [String]) async throws -> [TimedWord] {
        let pieces = try HostedPieces(audio, seconds: pieceSeconds)
        guard !pieces.starts.isEmpty else { return [] }
        let form = Form(languageCode: languageCode, hints: hints)
        var words: [Int: [TimedWord]] = [:]
        var limited: ProviderError?
        try await withThrowingTaskGroup(of: (Int, [TimedWord]?).self) { group in
            var next = pieces.starts.makeIterator()
            func add() -> Bool {
                guard let start = next.next() else { return false }
                group.addTask {
                    do {
                        return (start, try await piece(start, of: pieces, key: key, track: track, form: form))
                    } catch let error as ProviderError where error.kind == .sessionLimitReached {
                        return (start, nil)
                    }
                }
                return true
            }
            for _ in 0..<parallelPieces where !add() { break }
            while let (start, result) = try await group.next() {
                if let result {
                    words[start] = result
                    if limited == nil { _ = add() }
                } else {
                    // The meeting reached the plan's length: keep what came back, send nothing more.
                    limited = ProviderError(.mm2tPlan, .sessionLimitReached)
                }
            }
        }
        let kept = words.keys.sorted().flatMap { words[$0]! }
        if let limited, kept.isEmpty { throw limited }
        return kept
    }

    private struct Form: Sendable {
        let languageCode: String?
        let vocabulary: String?
        init(languageCode: String?, hints: [String]) {
            self.languageCode = languageCode
            let terms = hints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            vocabulary = terms.isEmpty ? nil : (try? JSONEncoder().encode(terms)).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    /// One piece, from the cache when this meeting already got it. A retry sends the bytes sent before,
    /// since the backend answers different bytes for a piece it has seen with `piece_conflict`.
    private func piece(_ start: Int, of pieces: HostedPieces, key: String, track: Track, form: Form) async throws -> [TimedWord] {
        let id = HostedLeases.Piece(meeting: key, track: track, start: start)
        if let words = await leases.result(id) { return words }
        let audio: Data
        if let sent = await leases.sent(id) {
            audio = sent
        } else {
            guard let encoded = try pieces.encoded(start) else { return [] }
            audio = encoded
            await leases.remember(audio, for: id)
        }
        let response = try await upload(audio, piece: id, form: form)
        let words = try SelfHostedTranscription.parse(response.body, service: .mm2tPlan).map {
            TimedWord($0.text, $0.range.start + Double(start), $0.range.end + Double(start))
        }
        await leases.store(words, for: id)
        return words
    }

    private func upload(_ audio: Data, piece: HostedLeases.Piece, form: Form) async throws -> HTTPResponse {
        var reopened = false
        while true {
            let lease = try await leases.lease(for: piece.meeting) { try await open(meeting: piece.meeting) }
            let response = try await authorization.send(session) { token in
                var multipart = MultipartForm()
                if let code = form.languageCode { multipart.add("language", code) }
                if let vocabulary = form.vocabulary { multipart.add("vocabulary", vocabulary) }
                multipart.addFile("file", filename: "piece.m4a", mimeType: "audio/mp4", data: audio)
                var request = URLRequest(url: baseURL.appending(path: "v1/transcriptions"), timeoutInterval: timeout)
                request.httpMethod = "POST"
                request.setValue("Bearer \(token.revealed)", forHTTPHeaderField: "Authorization")
                request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
                request.setValue(lease, forHTTPHeaderField: "X-MM2T-Session")
                request.setValue(String(piece.start), forHTTPHeaderField: "X-MM2T-Piece")
                request.setValue(piece.track == .me ? "mic" : "system", forHTTPHeaderField: "X-MM2T-Track")
                request.httpBody = multipart.finished()
                return request
            }
            if response.status == 200 { return response }
            // A lease idle for ten minutes closes; a new one carries on, and its pieces are charged afresh.
            if response.status == 409, response.hostedCode == "session_closed" {
                await leases.closed(lease, meeting: piece.meeting)
                if !reopened {
                    reopened = true
                    continue
                }
            }
            throw ProviderError(.mm2tPlan, response.hostedFailure)
        }
    }

    // MARK: Lease

    private var sessionsURL: URL { baseURL.deletingLastPathComponent().appending(path: "sessions") }

    /// After `session_active`, finish any leases left by a crash or an idle meeting before retrying the open.
    private func open(meeting: String) async throws -> String {
        let first = try await post(sessionsURL)
        if first.status == 409, first.hostedCode == "session_active" {
            let abandoned = await leases.abandoned(except: meeting)
            if !abandoned.isEmpty {
                for id in abandoned { await finish(id) }
                return try lease(from: try await post(sessionsURL))
            }
        }
        return try lease(from: first)
    }

    private struct LeaseBody: Decodable { let id: String }

    private func lease(from response: HTTPResponse) throws -> String {
        guard response.status == 200 || response.status == 201 else {
            throw ProviderError(.mm2tPlan, response.hostedFailure)
        }
        guard let lease = try? JSONDecoder().decode(LeaseBody.self, from: response.body) else {
            throw ProviderError(.mm2tPlan, .malformedResponse)
        }
        return lease.id
    }

    private func finish(_ id: String) async {
        let url = sessionsURL.appending(component: id).appending(path: "finish")
        guard let response = try? await post(url),
              (200..<300).contains(response.status) || response.status == 404
                || (response.status == 409 && response.hostedCode == "session_closed") else { return }
        await leases.finished(id)
    }

    private func post(_ url: URL) async throws -> HTTPResponse {
        try await authorization.send(session) { token in
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token.revealed)", forHTTPHeaderField: "Authorization")
            return request
        }
    }
}

/// The audio of one track, cut on whole seconds.
struct HostedPieces: Sendable {
    let url: URL
    let sampleRate: Double
    let frames: AVAudioFramePosition
    let seconds: Int

    init(_ url: URL, seconds: Int) throws {
        guard let file = try? AVAudioFile(forReading: url) else { throw ProviderError(.mm2tPlan, .audioUnreadable) }
        self.url = url
        sampleRate = file.processingFormat.sampleRate
        frames = file.length
        self.seconds = seconds
    }

    var starts: [Int] {
        guard sampleRate > 0 else { return [] }
        let duration = Double(frames) / sampleRate
        return Array(stride(from: 0, to: Int(duration.rounded(.up)), by: seconds))
    }

    /// The piece as 32 kbps AAC, or nil when it holds only digital silence, which costs minutes and has no words.
    func encoded(_ start: Int) throws -> Data? {
        do {
            let input = try AVAudioFile(forReading: url)
            let format = input.processingFormat
            let first = AVAudioFramePosition(Double(start) * sampleRate)
            let last = min(frames, AVAudioFramePosition(Double(start + seconds) * sampleRate))
            guard last > first, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(last - first)) else {
                return nil
            }
            input.framePosition = first
            try input.read(into: buffer, frameCount: AVAudioFrameCount(last - first))
            guard !Self.isSilent(buffer) else { return nil }
            return try Self.aac(buffer)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError(.mm2tPlan, .audioUnreadable)
        }
    }

    private static func isSilent(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData else { return false }
        let floor: Float = 1.0 / 32768
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength))
            if samples.contains(where: { abs($0) > floor }) { return false }
        }
        return true
    }

    private static func aac(_ buffer: AVAudioPCMBuffer) throws -> Data {
        let out = FileManager.default.temporaryDirectory.appending(path: "mm2t-piece-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: out) }
        try write(buffer, to: out)
        return try Data(contentsOf: out)
    }

    /// Separate so the writer is released, and its file finalized, before the caller reads it.
    private static func write(_ buffer: AVAudioPCMBuffer, to out: URL) throws {
        let format = buffer.format
        let output = try AVAudioFile(
            forWriting: out,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: 32_000,
            ],
            commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        try output.write(from: buffer)
    }
}

/// The plan's leases on this Mac, and what each meeting's pieces got back. One lives for the app's
/// lifetime so a retried meeting reuses its lease and resends identical bytes.
public actor HostedLeases {
    struct Piece: Hashable, Sendable {
        let meeting: String
        let track: Track
        let start: Int
    }

    private var opening: [String: Task<String, any Error>] = [:]
    private var leaseIDs: [String: String] = [:]
    private var users: [String: Int] = [:]
    private var sentAudio: [Piece: Data] = [:]
    private var results: [Piece: [TimedWord]] = [:]
    private let recall: @Sendable () -> [String]
    private let keep: @Sendable ([String]) -> Void

    /// `recall` and `keep` persist open lease ids, so one a crash left open can be finished next launch.
    public init(recall: @escaping @Sendable () -> [String] = { [] }, keep: @escaping @Sendable ([String]) -> Void = { _ in }) {
        self.recall = recall
        self.keep = keep
    }

    func withUse<T: Sendable>(of meeting: String, _ work: @Sendable () async throws -> T) async rethrows -> T {
        users[meeting, default: 0] += 1
        defer {
            if users[meeting] == 1 { users[meeting] = nil }
            else { users[meeting, default: 0] -= 1 }
        }
        return try await work()
    }

    func lease(for meeting: String, open: @escaping @Sendable () async throws -> String) async throws -> String {
        if let id = leaseIDs[meeting] { return id }
        if let task = opening[meeting] { return try await task.value }

        let task = Task {
            defer { opening[meeting] = nil }
            let id = try await open()
            leaseIDs[meeting] = id
            let remembered = recall()
            if !remembered.contains(id) { keep(remembered + [id]) }
            return id
        }
        opening[meeting] = task
        return try await task.value
    }

    func closed(_ id: String, meeting: String) {
        if leaseIDs[meeting] == id { leaseIDs[meeting] = nil }
        finished(id)
    }

    /// Lease ids to finish before opening another: remembered ones and other meetings' leases not in use.
    func abandoned(except meeting: String) -> [String] {
        var ids = Set(recall())
        var protected: Set<String> = []
        for (key, id) in leaseIDs {
            if key == meeting || users[key] != nil {
                protected.insert(id)
            } else {
                leaseIDs[key] = nil
                clear(key)
                ids.insert(id)
            }
        }
        return Array(ids.subtracting(protected))
    }

    /// Forgets the meeting and returns its lease to finish.
    func end(_ meeting: String) async -> String? {
        clear(meeting)
        if let task = opening[meeting] {
            guard let id = try? await task.value, leaseIDs[meeting] == id else { return nil }
        }
        return leaseIDs.removeValue(forKey: meeting)
    }

    func finished(_ id: String) {
        keep(recall().filter { $0 != id })
    }

    func result(_ piece: Piece) -> [TimedWord]? { results[piece] }
    func sent(_ piece: Piece) -> Data? { sentAudio[piece] }
    func remember(_ audio: Data, for piece: Piece) { sentAudio[piece] = audio }

    func store(_ words: [TimedWord], for piece: Piece) {
        results[piece] = words
        sentAudio[piece] = nil
    }

    private func clear(_ meeting: String) {
        sentAudio = sentAudio.filter { $0.key.meeting != meeting }
        results = results.filter { $0.key.meeting != meeting }
    }
}
