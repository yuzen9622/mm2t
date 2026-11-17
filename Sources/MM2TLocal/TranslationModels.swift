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

/// The files of one Bergamot translation direction. A model with one vocabulary for both
/// languages uses the same file for both.
public struct TranslationDirection: Hashable, Sendable {
    public let pair: ModelPair
    public let model: PinnedModelFile
    public let shortlist: PinnedModelFile
    public let sourceVocabulary: PinnedModelFile
    public let targetVocabulary: PinnedModelFile

    public init(pair: ModelPair, model: PinnedModelFile, shortlist: PinnedModelFile,
                sourceVocabulary: PinnedModelFile, targetVocabulary: PinnedModelFile) {
        self.pair = pair
        self.model = model
        self.shortlist = shortlist
        self.sourceVocabulary = sourceVocabulary
        self.targetVocabulary = targetVocabulary
    }

    /// Folder name under the translation models directory, such as `en-ko`.
    public var folder: String { pair.description }

    var files: [PinnedModelFile] {
        [model, shortlist, sourceVocabulary, targetVocabulary].reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    var fingerprint: String { files.map { "\($0.url.absoluteString) \($0.sha256)" }.joined(separator: "\n") }
}

/// Where a direction's files are once installed.
public struct TranslationModelPaths: Hashable, Sendable {
    public let model: URL
    public let shortlist: URL
    public let sourceVocabulary: URL
    public let targetVocabulary: URL
}

/// On-device translation models for live captions, from Mozilla (MPL-2.0). `mozilla(in:)` lists
/// every direction the app knows; `for(_:)` narrows it to what one target language needs, which is
/// all that is fetched or loaded. Each direction is installed on its own: installed means a marker
/// naming its pinned hashes sits in its folder, written only after its last file is verified. A
/// partial download resumes, a file whose hash does not match is deleted, and installing one
/// target's models never removes another's.
public struct TranslationModels: Sendable {
    public let directory: URL
    public let directions: [TranslationDirection]

    public init(directory: URL, directions: [TranslationDirection]) {
        self.directory = directory
        self.directions = directions
    }

    static let markerName = ".mm2t-translation"

    /// Only the directions translating into `target` needs.
    public func `for`(_ target: CaptionTarget) -> TranslationModels {
        let pairs = target.modelPairs
        return TranslationModels(directory: directory, directions: directions.filter { pairs.contains($0.pair) })
    }

    /// Bytes on the wire for every file, as a download from nothing fetches them.
    public var downloadBytes: Int64 { directions.flatMap(\.files).reduce(0) { $0 + $1.compressedSize } }

    public var isDownloaded: Bool { directions.allSatisfy(isInstalled) }

    func isInstalled(_ direction: TranslationDirection) -> Bool {
        let marker = try? String(contentsOf: directory.appending(path: direction.folder).appending(path: Self.markerName), encoding: .utf8)
        return marker == direction.fingerprint
    }

    public func direction(_ pair: ModelPair) -> TranslationDirection? {
        directions.first { $0.pair == pair }
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
            let missing = directions.filter { !isInstalled($0) }
            let total = max(missing.flatMap(\.files).reduce(0) { $0 + $1.compressedSize }, 1)
            let counter = ByteCounter { progress(min(Double($0) / Double(total), 0.999)) }
            for direction in missing {
                let folder = directory.appending(path: direction.folder)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for file in direction.files {
                    try await install(file, in: folder, configuration: configuration, counter: counter)
                }
                try direction.fingerprint.write(to: folder.appending(path: Self.markerName), atomically: true, encoding: .utf8)
            }
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
    /// Mozilla's Firefox Translations models, the released `base-memory` model of each direction,
    /// from the registry `https://storage.googleapis.com/moz-fx-translations-data--303e-prod-translations-data/db/models.json`
    /// (generated 2026-11-17). `en-ko` is the one released for Android (Firefox desktop ships an
    /// older, larger `base` model that scores lower). The registry hashes only each decompressed
    /// model; every other hash here was computed from the files downloaded on 2026-11-17.
    public static func mozilla(in models: URL) -> TranslationModels {
        let base = "https://storage.googleapis.com/moz-fx-translations-data--303e-prod-translations-data/models/"
        func file(_ path: String, _ compressedSize: Int64, _ compressedSHA256: String, _ size: Int64, _ sha256: String) -> PinnedModelFile {
            let url = URL(string: base + path)!
            return PinnedModelFile(url: url, name: String(url.lastPathComponent.dropLast(".gz".count)),
                                   compressedSize: compressedSize, compressedSHA256: compressedSHA256, size: size, sha256: sha256)
        }
        return TranslationModels(directory: models.appending(path: "translation"), directions: [
            TranslationDirection(
                pair: ModelPair("en", "zh_hant"),
                model: file("en-zh_hant/zh_hant_llmaat_finetune10M_qe8_f2_aQ8azdOMQOSBVjBDOVDIZQ/exported/model.enzh_hant.intgemm.alphas.bin.gz",
                     33_291_007, "79cb710e5e66bb0490368bf158f42aff800a0f9ef2f6449d98dfb654f2d02669",
                     43_849_787, "559ab90d723a58c1f1e2ab7cc12137bc667af5ba3e325e3eb30b5cdc930db520"),
                shortlist: file("en-zh_hant/zh_hant_llmaat_finetune10M_qe8_f2_aQ8azdOMQOSBVjBDOVDIZQ/exported/lex.50.50.enzh_hant.s2t.bin.gz",
                     2_290_215, "b254c97043a9ba5ff2791abac8b411dc024de6257576745a522ccc6c92421870",
                     4_057_188, "d891404d1436a7334df12539fe30a26f9e9f2b80bd42fdb8b5f8849e8a1e942b"),
                sourceVocabulary: file("en-zh_hant/zh_hant_llmaat_finetune10M_qe8_f2_aQ8azdOMQOSBVjBDOVDIZQ/exported/srcvocab.enzh_hant.spm.gz",
                     404_976, "5ad55cf62d3e8b0a1cefacc0086b1ceb26d0df6415205714effa76bbb1a3063b",
                     803_694, "2266df70492162a249ab1c0154f929bd6098b246544c666c1a0d5a24dde7d2ea"),
                targetVocabulary: file("en-zh_hant/zh_hant_llmaat_finetune10M_qe8_f2_aQ8azdOMQOSBVjBDOVDIZQ/exported/trgvocab.enzh_hant.spm.gz",
                     416_659, "324622c18601da5784569eeda74b77e5ae96b164657eb8029a9dabfdcd29803b",
                     751_671, "22b91a4436d70b91ab8777c677252ab5fae2bc284d71f977df5206c110e3444c")),
            TranslationDirection(
                pair: ModelPair("zh_hant", "en"),
                model: file("zh_hant-en/zh_hant_openlid_zh_tw_lr0002_WJi5Ozi7SZWC6hgfD5GhTA/exported/model.zh_hanten.intgemm.alphas.bin.gz",
                     33_653_648, "07af851b5a9160e84f3327e6f6151725e2712bed7b6b86edde5920fae107e55b",
                     43_849_787, "0aee91790894458f5d367551f6edcd4c9cb97852c34f221bcbf9f4701ebcf0cd"),
                shortlist: file("zh_hant-en/zh_hant_openlid_zh_tw_lr0002_WJi5Ozi7SZWC6hgfD5GhTA/exported/lex.50.50.zh_hanten.s2t.bin.gz",
                     3_268_812, "69046bfea1a70a556b5669be3c014958698683ef3c3f00b8dfd5c6b4e8f4f8ca",
                     6_385_944, "aa7daf6cfc85c0cd2c10e2944d66f6da55497c9c6408789f3adfded4074c2fb1"),
                sourceVocabulary: file("zh_hant-en/zh_hant_openlid_zh_tw_lr0002_WJi5Ozi7SZWC6hgfD5GhTA/exported/srcvocab.zh_hanten.spm.gz",
                     423_691, "e28a5484fce525e13a6cde4737b2fac08cb3c9cc60c13da9a6395c38833f7936",
                     769_669, "5cc6a76611dbf86219f109141533606b15ecb34eee83673bb86b2c16b14734db"),
                targetVocabulary: file("zh_hant-en/zh_hant_openlid_zh_tw_lr0002_WJi5Ozi7SZWC6hgfD5GhTA/exported/trgvocab.zh_hanten.spm.gz",
                     408_143, "071d675ee1a1b5faffbde94910814998f187df9717b007ae56d54d0a6ae791ac",
                     812_572, "7bf002db37c10d3b114cc5588d7fdcb16c57d0fd1e2c34354c22cc9f0b6c3c29")),
            TranslationDirection(
                pair: ModelPair("en", "zh"),
                model: file("en-zh/llmaat_finetune10M_qe8_f2_ByQcSxGXQRqGi-UTxYE43g/exported/model.enzh.intgemm.alphas.bin.gz",
                     33_375_922, "7f255403b3bb2502f08ac4d5ca397a8a5a13f899d2f2e987a4934e089d241d16",
                     43_849_787, "4e5accc141373565ddc8fa1565bceaa8d0c3482a82cab8131c719ebcc6c2157c"),
                shortlist: file("en-zh/llmaat_finetune10M_qe8_f2_ByQcSxGXQRqGi-UTxYE43g/exported/lex.50.50.enzh.s2t.bin.gz",
                     2_536_039, "806f75821c0b838f4a8f4afe5bab3db8289cb7e5187753ba04c3bceadd75687a",
                     4_485_184, "8575d8daa10e2dbff316dcdf8e1ce475357bcc2c92bdc63b736a2d5add22f681"),
                sourceVocabulary: file("en-zh/llmaat_finetune10M_qe8_f2_ByQcSxGXQRqGi-UTxYE43g/exported/srcvocab.enzh.spm.gz",
                     407_784, "7846e3c236388390f4e5d321f8413d67f34c1bab5f066165eeb673bfd07607cc",
                     806_952, "bd9b65504acc6d9726dd281f7defc2adb7c2c22d0688fe2f84697de25197c8c5"),
                targetVocabulary: file("en-zh/llmaat_finetune10M_qe8_f2_ByQcSxGXQRqGi-UTxYE43g/exported/trgvocab.enzh.spm.gz",
                     425_748, "4d641ce165b1f8478ee2ffb5149d2d46fab3779dc8fa1e9b97f9af1d2206c091",
                     772_004, "aded6993c36e440284d11cec3f6b8aef9c0e43188a772d80be342a713adf223d")),
            TranslationDirection(
                pair: ModelPair("en", "ko"),
                model: file("en-ko/cjk_retrain_base-memory_GP50C3MpQ9apCWZOW-f3PA/exported/model.enko.intgemm.alphas.bin.gz",
                     33_738_001, "91ebb959edc11b6ff63d28b5e237106047673e5be2dfec99169352fd98f0f1be",
                     43_849_787, "ffe5ef2ce3f2e944055e35310bab186f6a70d533a0ee4394adf716a0e383afbb"),
                shortlist: file("en-ko/cjk_retrain_base-memory_GP50C3MpQ9apCWZOW-f3PA/exported/lex.50.50.enko.s2t.bin.gz",
                     3_471_311, "062ceb1b1173f81c5ece40fb45affb5b7cbd8eaaf295e5744647d0e94b04beef",
                     6_449_612, "96efba97d4bb93ab362e5569bea0f115184d2f68d63b67305ee663c18e32fbeb"),
                sourceVocabulary: file("en-ko/cjk_retrain_base-memory_GP50C3MpQ9apCWZOW-f3PA/exported/srcvocab.enko.spm.gz",
                     402_480, "2227e5841e4376a3de47010a22f77762d9259c7459959744f2505721b93134a3",
                     791_280, "8d4e3141868efd410eb86c2b60d41aa6bc6b46e4c4b2c0b85e3792493c69d802"),
                targetVocabulary: file("en-ko/cjk_retrain_base-memory_GP50C3MpQ9apCWZOW-f3PA/exported/trgvocab.enko.spm.gz",
                     412_614, "676f821c4e0bab2f6b5af0e38fffdb7c053ad74ffa5a3e822e55fd2370af4008",
                     815_353, "2ece21b28dd7022d36127d17423a74dabf544787dfc1cf614f7b565f93a4a1d3")),
            TranslationDirection(
                pair: ModelPair("en", "ja"),
                model: file("en-ja/llmaat_finetune10M_qe8_f2_ApiGGQIwTKuF9i_k3n9Q2Q/exported/model.enja.intgemm.alphas.bin.gz",
                     33_052_218, "99fc8fc120189930beadacb2eef4b049d0794ac6132d1266340e457c95730368",
                     43_849_787, "59ae659f9bb63e4f81f474fe3c03d3f4499434b5f9e779fab7c12a45f31fd562"),
                shortlist: file("en-ja/llmaat_finetune10M_qe8_f2_ApiGGQIwTKuF9i_k3n9Q2Q/exported/lex.50.50.enja.s2t.bin.gz",
                     2_341_409, "7966382f7a9ba15993c67721526921d8901caa0f8add56eff04e4bb327d57c11",
                     4_128_360, "edfb7eb47b98a2689b804ab3614c31b24f1257aa54b1154da3d85e1ae8152d9f"),
                sourceVocabulary: file("en-ja/llmaat_finetune10M_qe8_f2_ApiGGQIwTKuF9i_k3n9Q2Q/exported/srcvocab.enja.spm.gz",
                     404_352, "12d8ffc83fc0bb61494d95701f6a298bbad5c999a043d4a48a1c1bd61e092167",
                     796_275, "970c98d174fc01e0339fbabbf45af36a4be3f26f819ec1a5ea1189f71e091889"),
                targetVocabulary: file("en-ja/llmaat_finetune10M_qe8_f2_ApiGGQIwTKuF9i_k3n9Q2Q/exported/trgvocab.enja.spm.gz",
                     431_278, "be7fec234b5fc94616276ee6cca69f3a8cbfa6762fdf278dfc6b11eaf669cc48",
                     827_144, "3b3d9f8f3a034d98d0a476f1794fa79c01e4e98a967ceb6777a66ba2d03ec1e1")),
            {
                let vocabulary = file("en-de/retrain_hr_fix_names_SCgGhxUPQ2WAECHLRtzrMg/exported/vocab.ende.spm.gz",
                     413_879, "3b2ddbfac73f994f151a8994447d6b3d41ab0d3435da56f79c233f34d03e45c2",
                     810_073, "69f730becafa48e3bb2c244eab66456877c08959a02f2bd5519b5a3088b62f9c")
                return TranslationDirection(
                    pair: ModelPair("en", "de"),
                    model: file("en-de/retrain_hr_fix_names_SCgGhxUPQ2WAECHLRtzrMg/exported/model.ende.intgemm.alphas.bin.gz",
                     22_992_073, "e3a74458faba3ab2752ed8355c5e3979f13395279c8fc1bd3f54a3c2316e4975",
                     31_561_787, "8df29d9494d19f47fd5d97c6a73474c6f657e9f81c1a607c431d02befdf3810f"),
                    shortlist: file("en-de/retrain_hr_fix_names_SCgGhxUPQ2WAECHLRtzrMg/exported/lex.50.50.ende.s2t.bin.gz",
                     2_314_750, "0370d79cda6fed5dfa8f9b2a0009459bd2766893825bb5b8b5114169d18da6c4",
                     4_347_672, "7ed39f1cffbd68a27ddf05bbfe068de2060f1d7e69f1a20e27ae923551dd7393"),
                    sourceVocabulary: vocabulary, targetVocabulary: vocabulary)
            }(),
            {
                let vocabulary = file("en-cs/retrain_hr_F_JF0vqvSjSwn3caQQcicA/exported/vocab.encs.spm.gz",
                     412_691, "842c1396415257eb864d1ce4722eece82f024a23ecdc4e1be5defcdf6b6d2c0e",
                     815_154, "ee4b8ce15c8e1237c5f7a2d04741341beb0a5d5c09820f7ec08f13ee2b212755")
                return TranslationDirection(
                    pair: ModelPair("en", "cs"),
                    model: file("en-cs/retrain_hr_F_JF0vqvSjSwn3caQQcicA/exported/model.encs.intgemm.alphas.bin.gz",
                     23_192_301, "363519c1560786f8c9c85737431ec61c770623b1ee99dff7b154019ab202d8d9",
                     31_561_787, "1d7855f91c3e2b8ef79fbea62707d46ceb8a1ad01834ef6dd500f32a7006cc2c"),
                    shortlist: file("en-cs/retrain_hr_F_JF0vqvSjSwn3caQQcicA/exported/lex.50.50.encs.s2t.bin.gz",
                     1_896_925, "e5e54ed7488b5beafef1947788534b6e3919ebe658d0a432ef00962bac1769ff",
                     3_572_436, "699b9b59fe3acbcddf831380024b2e139f2cbe225dce96d59ade2b159318f58b"),
                    sourceVocabulary: vocabulary, targetVocabulary: vocabulary)
            }(),
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
