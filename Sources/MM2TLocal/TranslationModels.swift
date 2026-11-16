import CryptoKit
import Foundation
import MM2TCore

/// One gzip-compressed model file at a fixed URL, with the bytes it must have on both sides of
/// decompression.
public struct PinnedModelFile: Hashable, Sendable {
    public let url: URL
    /// The name of the decompressed file on disk.
    public let name: String
    public let compressedSize: Int64
    public let compressedSHA256: String
    public let size: Int64
    public let sha256: String

    public init(url: URL, name: String, compressedSize: Int64, compressedSHA256: String, size: Int64, sha256: String) {
        self.url = url
        self.name = name
        self.compressedSize = compressedSize
        self.compressedSHA256 = compressedSHA256
        self.size = size
        self.sha256 = sha256
    }
}

/// The four files of one Bergamot translation direction.
public struct TranslationDirection: Hashable, Sendable {
    public let source: CaptionLanguage
    public let target: CaptionLanguage
    /// Folder name under the translation models directory.
    public let folder: String
    public let model: PinnedModelFile
    public let shortlist: PinnedModelFile
    public let sourceVocabulary: PinnedModelFile
    public let targetVocabulary: PinnedModelFile

    public init(source: CaptionLanguage, target: CaptionLanguage, folder: String, model: PinnedModelFile,
                shortlist: PinnedModelFile, sourceVocabulary: PinnedModelFile, targetVocabulary: PinnedModelFile) {
        self.source = source
        self.target = target
        self.folder = folder
        self.model = model
        self.shortlist = shortlist
        self.sourceVocabulary = sourceVocabulary
        self.targetVocabulary = targetVocabulary
    }

    var files: [PinnedModelFile] { [model, shortlist, sourceVocabulary, targetVocabulary] }
}

/// Where a direction's files are once installed.
public struct TranslationModelPaths: Hashable, Sendable {
    public let model: URL
    public let shortlist: URL
    public let sourceVocabulary: URL
    public let targetVocabulary: URL
}

/// The on-device translation models for live captions: Mozilla's `en -> zh_hant` and
/// `zh_hant -> en` (MPL-2.0), both installed together. Like `ModelSnapshot`, installed means a
/// marker naming every pinned hash exists, written only after the last file is verified; a
/// partial download resumes, and a file whose hash does not match is deleted.
public struct TranslationModels: Sendable {
    public let directory: URL
    public let directions: [TranslationDirection]

    public init(directory: URL, directions: [TranslationDirection]) {
        self.directory = directory
        self.directions = directions
    }

    static let markerName = ".mm2t-translation"

    var fingerprint: String {
        directions.flatMap(\.files).map { "\($0.url.absoluteString) \($0.sha256)" }.joined(separator: "\n")
    }

    /// Bytes on the wire for every file.
    public var downloadBytes: Int64 { directions.flatMap(\.files).reduce(0) { $0 + $1.compressedSize } }

    public var isDownloaded: Bool {
        let marker = try? String(contentsOf: directory.appending(path: Self.markerName), encoding: .utf8)
        return marker == fingerprint
    }

    public func direction(from source: CaptionLanguage, to target: CaptionLanguage) -> TranslationDirection? {
        directions.first { $0.source == source && $0.target == target }
    }

    public func paths(_ direction: TranslationDirection) -> TranslationModelPaths {
        let folder = directory.appending(path: direction.folder)
        return TranslationModelPaths(
            model: folder.appending(path: direction.model.name),
            shortlist: folder.appending(path: direction.shortlist.name),
            sourceVocabulary: folder.appending(path: direction.sourceVocabulary.name),
            targetVocabulary: folder.appending(path: direction.targetVocabulary.name))
    }

    /// Fetches whatever is missing; `progress` receives 0...1 by compressed bytes.
    public func download(
        configuration: URLSessionConfiguration = .default,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        if isDownloaded { return progress(1) }
        do {
            let total = max(downloadBytes, 1)
            let counter = ByteCounter { progress(min(Double($0) / Double(total), 0.999)) }
            for direction in directions {
                let folder = directory.appending(path: direction.folder)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for file in direction.files {
                    try await install(file, in: folder, configuration: configuration, counter: counter)
                }
            }
            try fingerprint.write(to: directory.appending(path: Self.markerName), atomically: true, encoding: .utf8)
        } catch let error as LocalModelError {
            throw error
        } catch {
            throw LocalModelError.downloadFailed(String(describing: error))
        }
        progress(1)
    }

    private func install(_ file: PinnedModelFile, in folder: URL, configuration: URLSessionConfiguration,
                         counter: ByteCounter) async throws {
        let destination = folder.appending(path: file.name)
        // A file in place was verified before it was moved there.
        if fileSize(destination) == file.size {
            counter.add(file.compressedSize)
            return
        }
        let compressed = folder.appending(path: file.name + ".gz")
        let partial = compressed.appendingPathExtension("part")
        var offset = fileSize(partial) ?? 0
        if offset > file.compressedSize {
            try FileManager.default.removeItem(at: partial)
            offset = 0
        }
        if offset == 0 { FileManager.default.createFile(atPath: partial.path, contents: nil) }
        counter.add(offset)
        try await StreamedFile.fetch(file.url, offset: offset, to: partial, configuration: configuration, counter: counter)

        guard fileSize(partial) == file.compressedSize, try Self.sha256(of: partial) == file.compressedSHA256 else {
            try? FileManager.default.removeItem(at: partial)
            throw LocalModelError.downloadFailed("\(file.name): the download does not match its pinned SHA-256")
        }
        let data = try Gzip.decompress(Data(contentsOf: partial))
        try? FileManager.default.removeItem(at: partial)
        guard Int64(data.count) == file.size, Self.sha256(data) == file.sha256 else {
            throw LocalModelError.downloadFailed("\(file.name): the decompressed file does not match its pinned SHA-256")
        }
        let staged = destination.appendingPathExtension("part")
        try data.write(to: staged)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: staged, to: destination)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

extension TranslationModels {
    /// Mozilla's Firefox Translations models, release `base-memory` architecture, as listed in
    /// the registry `https://storage.googleapis.com/moz-fx-translations-data--303e-prod-translations-data/db/models.json`
    /// (generated 2026-11-16). The registry gives a hash only for each decompressed model; every
    /// other hash here was computed from the files downloaded on 2026-11-16.
    public static func mozilla(in models: URL) -> TranslationModels {
        let base = "https://storage.googleapis.com/moz-fx-translations-data--303e-prod-translations-data/models/"
        func file(_ path: String, _ compressedSize: Int64, _ compressedSHA256: String, _ size: Int64, _ sha256: String) -> PinnedModelFile {
            let url = URL(string: base + path)!
            return PinnedModelFile(url: url, name: String(url.lastPathComponent.dropLast(".gz".count)),
                                   compressedSize: compressedSize, compressedSHA256: compressedSHA256, size: size, sha256: sha256)
        }
        let toChinese = "en-zh_hant/zh_hant_llmaat_finetune10M_qe8_f2_aQ8azdOMQOSBVjBDOVDIZQ/exported/"
        let toEnglish = "zh_hant-en/zh_hant_openlid_zh_tw_lr0002_WJi5Ozi7SZWC6hgfD5GhTA/exported/"
        return TranslationModels(directory: models.appending(path: "translation"), directions: [
            TranslationDirection(
                source: .english, target: .traditionalChinese, folder: "en-zh_hant",
                model: file(toChinese + "model.enzh_hant.intgemm.alphas.bin.gz",
                            33_291_007, "79cb710e5e66bb0490368bf158f42aff800a0f9ef2f6449d98dfb654f2d02669",
                            43_849_787, "559ab90d723a58c1f1e2ab7cc12137bc667af5ba3e325e3eb30b5cdc930db520"),
                shortlist: file(toChinese + "lex.50.50.enzh_hant.s2t.bin.gz",
                                2_290_215, "b254c97043a9ba5ff2791abac8b411dc024de6257576745a522ccc6c92421870",
                                4_057_188, "d891404d1436a7334df12539fe30a26f9e9f2b80bd42fdb8b5f8849e8a1e942b"),
                sourceVocabulary: file(toChinese + "srcvocab.enzh_hant.spm.gz",
                                       404_976, "5ad55cf62d3e8b0a1cefacc0086b1ceb26d0df6415205714effa76bbb1a3063b",
                                       803_694, "2266df70492162a249ab1c0154f929bd6098b246544c666c1a0d5a24dde7d2ea"),
                targetVocabulary: file(toChinese + "trgvocab.enzh_hant.spm.gz",
                                       416_659, "324622c18601da5784569eeda74b77e5ae96b164657eb8029a9dabfdcd29803b",
                                       751_671, "22b91a4436d70b91ab8777c677252ab5fae2bc284d71f977df5206c110e3444c")),
            TranslationDirection(
                source: .traditionalChinese, target: .english, folder: "zh_hant-en",
                model: file(toEnglish + "model.zh_hanten.intgemm.alphas.bin.gz",
                            33_653_648, "07af851b5a9160e84f3327e6f6151725e2712bed7b6b86edde5920fae107e55b",
                            43_849_787, "0aee91790894458f5d367551f6edcd4c9cb97852c34f221bcbf9f4701ebcf0cd"),
                shortlist: file(toEnglish + "lex.50.50.zh_hanten.s2t.bin.gz",
                                3_268_812, "69046bfea1a70a556b5669be3c014958698683ef3c3f00b8dfd5c6b4e8f4f8ca",
                                6_385_944, "aa7daf6cfc85c0cd2c10e2944d66f6da55497c9c6408789f3adfded4074c2fb1"),
                sourceVocabulary: file(toEnglish + "srcvocab.zh_hanten.spm.gz",
                                       423_691, "e28a5484fce525e13a6cde4737b2fac08cb3c9cc60c13da9a6395c38833f7936",
                                       769_669, "5cc6a76611dbf86219f109141533606b15ecb34eee83673bb86b2c16b14734db"),
                targetVocabulary: file(toEnglish + "trgvocab.zh_hanten.spm.gz",
                                       408_143, "071d675ee1a1b5faffbde94910814998f187df9717b007ae56d54d0a6ae791ac",
                                       812_572, "7bf002db37c10d3b114cc5588d7fdcb16c57d0fd1e2c34354c22cc9f0b6c3c29")),
        ])
    }
}

/// RFC 1952 gzip, read with the system's raw-deflate decoder.
enum Gzip {
    struct Invalid: Error, CustomStringConvertible {
        var description: String { "not a valid gzip file" }
    }

    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { throw Invalid() }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard offset + 2 <= bytes.count else { throw Invalid() }
            offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {  // FNAME, FCOMMENT: zero-terminated
            guard let end = bytes[min(offset, bytes.count)...].firstIndex(of: 0) else { throw Invalid() }
            offset = end + 1
        }
        if flags & 0x02 != 0 { offset += 2 }  // FHCRC
        guard offset < bytes.count - 8 else { throw Invalid() }
        let deflated = Data(bytes[offset..<(bytes.count - 8)])
        let inflated = try (deflated as NSData).decompressed(using: .zlib) as Data
        let trailer = bytes.suffix(4)
        let expected = trailer.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard UInt32(truncatingIfNeeded: inflated.count) == expected else { throw Invalid() }
        return inflated
    }
}
