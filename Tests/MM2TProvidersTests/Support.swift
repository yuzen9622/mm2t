import Foundation
@testable import MM2TCore
@testable import MM2TProviders

/// A fake network at the URLSession boundary. Each instance owns a session whose requests it
/// answers, so suites can run in parallel.
final class StubServer: @unchecked Sendable {
    struct Request {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data

        var bodyText: String { String(decoding: body, as: UTF8.self) }

        /// Text fields of a multipart body, in order; file parts are omitted.
        var formFields: [(name: String, value: String)] {
            guard let type = headers["Content-Type"], let boundary = type.components(separatedBy: "boundary=").last else { return [] }
            return bodyText.components(separatedBy: "--\(boundary)").compactMap { part in
                guard let headerEnd = part.range(of: "\r\n\r\n") else { return nil }
                let head = part[..<headerEnd.lowerBound]
                guard !head.contains("filename="), let nameStart = head.range(of: "name=\"") else { return nil }
                let name = head[nameStart.upperBound...].prefix { $0 != "\"" }
                var value = String(part[headerEnd.upperBound...])
                if value.hasSuffix("\r\n") { value.removeLast(1) }
                return (String(name), value)
            }
        }

        func field(_ name: String) -> [String] { formFields.filter { $0.name == name }.map(\.value) }
    }

    enum Reply {
        case status(Int, String)
        case failure(URLError.Code)
    }

    typealias Handler = @Sendable (Request) -> Reply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]

    let id = UUID().uuidString
    let session: URLSession
    private let lock = NSLock()
    private var handler: Handler
    private var received: [Request] = []

    init(_ handler: @escaping Handler) {
        self.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        config.httpAdditionalHeaders = [StubProtocol.header: id]
        session = URLSession(configuration: config)
        Self.lock.withLock { Self.servers[id] = self }
    }

    convenience init(status: Int, body: String) {
        self.init { _ in .status(status, body) }
    }

    deinit { Self.lock.withLock { _ = Self.servers.removeValue(forKey: id) } }

    var requests: [Request] { lock.withLock { received } }

    static func server(for id: String) -> StubServer? { lock.withLock { servers[id] } }

    fileprivate func reply(to request: Request) -> Reply {
        lock.withLock {
            received.append(request)
            return handler
        }(request)
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let header = "X-MM2T-Stub"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let server = request.value(forHTTPHeaderField: Self.header).flatMap(StubServer.server(for:)) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        var headers = request.allHTTPHeaderFields ?? [:]
        headers.removeValue(forKey: Self.header)
        let recorded = StubServer.Request(
            url: request.url!, method: request.httpMethod ?? "GET", headers: headers, body: Self.body(of: request))
        switch server.reply(to: recorded) {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .status(let status, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// One folder per test process, removed when it exits; one a crashed run left behind is swept an hour later.
let testScratch: URL = {
    let files = FileManager.default
    let parent = files.temporaryDirectory.appending(path: "mm2t-test-runs")
    for old in (try? files.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.creationDateKey])) ?? []
    where (try? old.resourceValues(forKeys: [.creationDateKey]).creationDate).flatMap { $0 } ?? .distantFuture
        < Date(timeIntervalSinceNow: -3600) {
        try? files.removeItem(at: old)
    }
    atexit { try? FileManager.default.removeItem(at: testScratch) }
    return parent.appending(path: UUID().uuidString)
}()

func audioFile(_ name: String = "remote.wav") throws -> URL {
    let dir = testScratch.appending(path: "mm2t-provider-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: name)
    try silentWAV(seconds: 0.2).write(to: url)
    return url
}

func utterance(_ id: String, _ speaker: String, _ start: Double, _ text: String, highlighted: Bool = false) -> LLMUtterance {
    LLMUtterance(
        id: UtteranceID(id), speaker: SpeakerID(speaker), range: TimeRange(start: start, end: start + 2),
        text: text, isHighlighted: highlighted)
}

/// Every message a provider can produce, to check none leaks a secret.
func allMessages(of error: Error) -> String {
    "\(error) \(String(describing: error)) \(String(reflecting: error)) \(error.localizedDescription)"
}

enum Fixture {
    /// Shape of `SpeechToTextChunkResponseModel` from the ElevenLabs API reference. Speaker ids
    /// appear only when the request asked for diarization, as the real service does.
    static func scribe(diarized: Bool) -> String {
        func speaker(_ n: Int) -> String { diarized ? "\"speaker_id\":\"speaker_\(n)\"," : "\"speaker_id\":null," }
        return """
        {"language_code":"zho","language_probability":0.97,"text":"大家好(笑聲)我是小明 Kubernetes cluster",
         "transcription_id":"tx_1","audio_duration_secs":4.2,
         "words":[
          {"text":"大家","start":0.10,"end":0.40,"type":"word",\(speaker(0))"logprob":-0.10},
          {"text":"好","start":0.40,"end":0.60,"type":"word",\(speaker(0))"logprob":-0.05},
          {"text":"(笑聲)","start":0.60,"end":1.00,"type":"audio_event",\(speaker(0))"logprob":0.0},
          {"text":"我是","start":1.00,"end":1.30,"type":"word",\(speaker(1))"logprob":-0.20},
          {"text":"小明","start":1.30,"end":1.70,"type":"word",\(speaker(1))"logprob":-0.30},
          {"text":" ","start":1.70,"end":1.75,"type":"spacing",\(speaker(1))"logprob":0.0},
          {"text":"Kubernetes","start":1.75,"end":2.40,"type":"word",\(speaker(1))"logprob":-0.40},
          {"text":" ","start":2.40,"end":2.45,"type":"spacing",\(speaker(1))"logprob":0.0},
          {"text":"cluster","start":2.45,"end":2.90,"type":"word",\(speaker(1))"logprob":-0.10}
         ]}
        """
    }

    /// Shape from server/README.md and `Transcript` in server/mm2t_server/engine.py.
    static let selfHosted = """
    {"model":"SoybeanMilk/faster-whisper-Breeze-ASR-25","language":"zh","duration":4.2,
     "segments":[
      {"start":0.0,"end":1.7,"text":"大家好我是小明","words":[
        {"word":"大家","start":0.0,"end":0.4,"probability":0.95},
        {"word":"好","start":0.4,"end":0.6,"probability":0.97},
        {"word":"我是","start":1.0,"end":1.3,"probability":0.9},
        {"word":"小明","start":1.3,"end":1.7,"probability":0.93}]},
      {"start":1.7,"end":2.9,"text":" Kubernetes cluster","words":[
        {"word":" Kubernetes","start":1.75,"end":2.4,"probability":0.88},
        {"word":" cluster","start":2.45,"end":2.9,"probability":0.91}]}
     ]}
    """

    static let health = #"{"status":"ok","model":"SoybeanMilk/faster-whisper-Breeze-ASR-25","device":"cuda"}"#

    /// A `GenerateContentResponse` whose single candidate carries `json` as its text part.
    static func gemini(_ json: String, finishReason: String = "STOP", thought: Bool = false) -> String {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: json, options: .fragmentsAllowed), as: UTF8.self)
        let thoughtPart = thought ? #"{"text":"Let me think about the speakers.","thought":true},"# : ""
        return """
        {"candidates":[{"content":{"role":"model","parts":[\(thoughtPart){"text":\(text)}]},
          "finishReason":"\(finishReason)","index":0}],
         "usageMetadata":{"promptTokenCount":812,"candidatesTokenCount":95,"totalTokenCount":907},
         "modelVersion":"gemini-3.8-flash","responseId":"resp_1"}
        """
    }

    static func googleError(_ code: Int, status: String, message: String, reason: String? = nil) -> String {
        let details = reason.map {
            #","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"\#($0)","domain":"googleapis.com"}]"#
        } ?? ""
        return #"{"error":{"code":\#(code),"message":"\#(message)","status":"\#(status)"\#(details)}}"#
    }
}
