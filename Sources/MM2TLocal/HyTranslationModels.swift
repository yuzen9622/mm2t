import Foundation

public struct HyTranslationModels: Sendable {
    static let filename = "Hy-MT2-1.8B-Q4_K_M.gguf"
    static let revision = "a0c709d9fac510f2c807aa3af52872340dc37a4a"
    static let sha256 = "dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699"
    let file: URL
    public let downloadBytes: Int64 = 1_133_080_448

    public init(in models: URL) {
        file = models.appending(path: "translation/hy-mt2/\(Self.revision)/\(Self.filename)")
    }

    // Only the fully verified staging file is renamed into this revision's directory.
    public var isDownloaded: Bool {
        (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(downloadBytes)
    }

    public func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        if isDownloaded { return progress(1) }
        let fm = FileManager.default
        let directory = file.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appending(path: "\(UUID()).part")
        guard fm.createFile(atPath: staging.path, contents: nil) else {
            throw LocalModelError.downloadFailed("Cannot stage \(Self.filename)")
        }
        defer { try? fm.removeItem(at: staging) }
        let url = URL(string: "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/\(Self.revision)/\(Self.filename)")!
        let counter = ByteCounter { progress(min(0.999, Double($0) / Double(downloadBytes))) }
        try await StreamedFile.fetch(url, offset: 0, to: staging, configuration: .ephemeral, counter: counter)
        guard try staging.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(downloadBytes),
              try TranslationModels.sha256(of: staging) == Self.sha256 else {
            throw LocalModelError.downloadFailed("\(Self.filename) does not match its pinned SHA-256")
        }
        try Task.checkCancellation()
        if fm.fileExists(atPath: file.path) {
            _ = try fm.replaceItemAt(file, withItemAt: staging)
        } else {
            do { try fm.moveItem(at: staging, to: file) }
            catch { if !isDownloaded { throw error } }
        }
        progress(1)
    }
}
