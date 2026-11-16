import CryptoKit
import Foundation
@testable import MM2TCore
import Testing
@testable import MM2TLocal

@Suite struct TranslationModelTests {
    /// One direction of two small files, served gzip-compressed by a fake server.
    struct Fixture {
        let models: TranslationModels
        let server: FakeFiles
        let contents: [String: Data]
    }

    func fixture(in directory: URL, corrupt: String? = nil) -> Fixture {
        // Noise, so the compressed model is large enough to stop halfway through.
        var seed: UInt32 = 7
        let noise = Data((0..<200_000).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return UInt8(seed >> 24)
        })
        let contents = ["model.bin": noise, "vocab.spm": Data("vocabulary".utf8)]
        var served: [String: Data] = [:]
        var pinned: [String: PinnedModelFile] = [:]
        for (name, data) in contents {
            let gz = gzip(data)
            let url = URL(string: "https://models.test/\(name).gz")!
            served[url.path] = name == corrupt ? Data(gz.reversed()) : gz
            pinned[name] = PinnedModelFile(url: url, name: name, compressedSize: Int64(gz.count),
                                           compressedSHA256: TranslationModels.sha256(gz),
                                           size: Int64(data.count), sha256: TranslationModels.sha256(data))
        }
        let direction = TranslationDirection(
            source: .english, target: .traditionalChinese, folder: "en-zh_hant",
            model: pinned["model.bin"]!, shortlist: pinned["vocab.spm"]!,
            sourceVocabulary: pinned["vocab.spm"]!, targetVocabulary: pinned["vocab.spm"]!)
        return Fixture(models: TranslationModels(directory: directory.appending(path: "translation"), directions: [direction]),
                       server: FakeFiles(files: served), contents: contents)
    }

    @Test func installsDecompressedVerifiedFilesAndThenReadsAsInstalled() async throws {
        let setup = fixture(in: try scratchDirectory())
        #expect(!setup.models.isDownloaded)
        let fractions = Fractions()
        try await setup.models.download(configuration: setup.server.configuration) { fractions.append($0) }

        #expect(setup.models.isDownloaded)
        let paths = setup.models.paths(setup.models.directions[0])
        #expect(try Data(contentsOf: paths.model) == setup.contents["model.bin"])
        #expect(try Data(contentsOf: paths.sourceVocabulary) == setup.contents["vocab.spm"])
        #expect(fractions.values.last == 1)
        #expect(fractions.values == fractions.values.sorted(), "progress never goes backwards")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.model.deletingLastPathComponent().path)
        #expect(leftovers.sorted() == ["model.bin", "vocab.spm"], "no compressed or partial files stay behind")
    }

    @Test func aFileThatDoesNotMatchItsHashIsDeletedAndNothingReadsAsInstalled() async throws {
        let directory = try scratchDirectory()
        let setup = fixture(in: directory, corrupt: "model.bin")
        await #expect(throws: LocalModelError.self) {
            try await setup.models.download(configuration: setup.server.configuration)
        }
        #expect(!setup.models.isDownloaded)
        let folder = setup.models.paths(setup.models.directions[0]).model.deletingLastPathComponent()
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        #expect(!left.contains { $0.hasPrefix("model.bin") }, "the mismatching download is gone")
    }

    @Test func anInterruptedDownloadResumesWhereItStopped() async throws {
        let directory = try scratchDirectory()
        let setup = fixture(in: directory)
        let file = setup.models.directions[0].model
        let folder = setup.models.directory.appending(path: "en-zh_hant")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let served = setup.server.files[file.url.path]!
        #expect(served.count > 100_000)
        try served.prefix(100_000).write(to: folder.appending(path: "model.bin.gz.part"))

        try await setup.models.download(configuration: setup.server.configuration)
        #expect(setup.models.isDownloaded)
        #expect(setup.server.requests.contains { $0.path == file.url.path && $0.range == "bytes=100000-" })
    }

    @Test func gzipWithAFileNameHeaderDecompresses() throws {
        let data = Data("字幕 captions".utf8)
        var gz = gzip(data)
        // Same stream with FNAME set and a name inserted after the fixed header.
        gz[3] = 0x08
        gz.insert(contentsOf: Data("name.bin\0".utf8), at: 10)
        #expect(try Gzip.decompress(gz) == data)
        #expect(throws: Gzip.Invalid.self) { try Gzip.decompress(Data("plain".utf8)) }
    }

    @Test func thePinnedMozillaModelsCoverBothDirections() {
        let models = TranslationModels.mozilla(in: URL(filePath: "/tmp/none"))
        #expect(models.direction(from: .english, to: .traditionalChinese) != nil)
        #expect(models.direction(from: .traditionalChinese, to: .english) != nil)
        #expect(models.downloadBytes > 70_000_000 && models.downloadBytes < 80_000_000)
        for file in models.directions.flatMap(\.files) {
            #expect(file.url.host() == "storage.googleapis.com")
            #expect(file.sha256.count == 64 && file.compressedSHA256.count == 64)
        }
    }
}

/// Runs the real engine on the real models when both are present (`MM2T_LOCAL_MODELS` holding a
/// `translation/` folder in the app's layout), printing each translation and its time.
@Suite(.serialized) struct RealTranslationTests {
    static var models: TranslationModels? {
        guard let root = RealModels.root else { return nil }
        let models = TranslationModels.mozilla(in: root)
        let present = models.directions.allSatisfy { direction in
            let paths = models.paths(direction)
            return [paths.model, paths.shortlist, paths.sourceVocabulary, paths.targetVocabulary]
                .allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        }
        return present ? models : nil
    }

    static let english = [
        "Let's move on to the next agenda item, which is the Q3 budget review.",
        "Can everyone see my screen, or should I zoom in a little?",
        "I think we should push the release to next Thursday because QA found two blocking bugs.",
        "John, could you take the action item to follow up with the vendor about the contract?",
        "We need to reduce the latency of the speech recognition pipeline before the demo.",
        "Sorry, I missed that. Could you repeat the last part about the migration timeline?",
        "The customer is asking whether we can support single sign-on by the end of this quarter.",
        "Let's table this discussion and revisit it after we have more data from the pilot.",
        "Our diarization error rate on Mandarin meetings is still higher than we would like.",
        "Thanks everyone for joining, I will send out the meeting notes by this afternoon.",
    ]
    static let chinese = [
        "我們先進入下一個議程，也就是第三季的預算檢討。",
        "大家看得到我的螢幕嗎？還是我需要放大一點？",
        "我認為應該把發布日期延到下週四，因為品管發現了兩個阻擋上線的錯誤。",
        "小明，你可以負責跟廠商確認合約的後續事項嗎？",
        "在展示之前，我們必須降低語音辨識流程的延遲。",
        "不好意思我剛剛沒聽清楚，可以再說一次關於遷移時程的部分嗎？",
        "客戶想知道我們能不能在本季結束前支援單一登入。",
        "這個議題先擱置，等試行計畫有更多資料之後再回來討論。",
        "我們在中文會議上的語者分離錯誤率還是比預期高。",
        "謝謝大家參加，我今天下午會把會議紀錄寄出去。",
    ]

    @Test(.enabled(if: models != nil)) func translatesBothWaysOnThisMac() async throws {
        let translator = BergamotTranslator(models: Self.models!)
        for (sentences, source, target) in [(Self.english, CaptionLanguage.english, CaptionLanguage.traditionalChinese),
                                            (Self.chinese, .traditionalChinese, .english)] {
            let clock = ContinuousClock()
            let load = try await clock.measure { _ = try await translator.translate("Hello.", from: source, to: target) }
            var times: [Duration] = []
            for sentence in sentences {
                var output = ""
                times.append(try await clock.measure { output = try await translator.translate(sentence, from: source, to: target) })
                print("\(source) -> \(target): \(sentence) => \(output)")
                #expect(CaptionLanguage.of(output) == target)
            }
            let sorted = times.sorted()
            print("\(source) -> \(target): first call with load \(load), median \(sorted[sorted.count / 2]), max \(sorted.last!)")
        }
        await translator.unload()
    }

    @Test(.enabled(if: models != nil)) func aMissingModelFileIsAnErrorNotACrash() async throws {
        let empty = TranslationModels(directory: try scratchDirectory(), directions: Self.models!.directions)
        let translator = BergamotTranslator(models: empty)
        await #expect(throws: CaptionTranslationError.self) {
            _ = try await translator.translate("Hello.", from: .english, to: .traditionalChinese)
        }
    }
}

// MARK: Support

/// gzip as RFC 1952 lays it out, around the system's raw deflate.
func gzip(_ data: Data) -> Data {
    var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
    out += try! (data as NSData).compressed(using: .zlib) as Data
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
    }
    for value in [~crc, UInt32(truncatingIfNeeded: data.count)] {
        out += Data([UInt8(value & 0xff), UInt8(value >> 8 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 24)])
    }
    return out
}

/// Fixed files by URL path at the URLSession boundary, with HTTP Range.
final class FakeFiles: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: FakeFiles] = [:]

    let id = UUID().uuidString
    let files: [String: Data]
    private let lock = NSLock()
    private var seen: [FakeHub.Seen] = []

    init(files: [String: Data]) {
        self.files = files
        Self.lock.withLock { Self.servers[id] = self }
    }

    deinit { Self.lock.withLock { _ = Self.servers.removeValue(forKey: id) } }

    var configuration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeFilesProtocol.self]
        config.httpAdditionalHeaders = [FakeFilesProtocol.header: id]
        return config
    }

    var requests: [FakeHub.Seen] { lock.withLock { seen } }

    static func server(_ id: String) -> FakeFiles? { lock.withLock { servers[id] } }

    func answer(_ request: URLRequest) -> (Int, [String: String], Data) {
        let path = request.url!.path
        let range = request.value(forHTTPHeaderField: "Range")
        lock.withLock { seen.append(.init(path: path, range: range)) }
        guard let body = files[path] else { return (404, [:], Data()) }
        if let range, let start = Int(range.dropFirst("bytes=".count).dropLast()) {
            return (206, ["Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)"], body.subdata(in: start..<body.count))
        }
        return (200, [:], body)
    }
}

final class FakeFilesProtocol: URLProtocol, @unchecked Sendable {
    static let header = "X-MM2T-Files"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: Self.header), let server = FakeFiles.server(id) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (status, headers, body) = server.answer(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
