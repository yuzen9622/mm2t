import Foundation

/// 16-bit PCM mono WAV written incrementally. Audio bytes are appended first and the header's
/// size fields are rewritten after each flush, so the file on disk is a valid WAV covering
/// everything up to the last flush even if the process dies mid-recording.
public final class WAVWriter {
    public let url: URL
    public let sampleRate: Int
    public private(set) var framesWritten = 0
    private let handle: FileHandle
    private var pending = Data()
    private var flushesSinceSync = 0
    private let syncEvery: Int

    /// `syncEvery`: fsync after this many flushes; app crashes only need the write, power loss needs the sync.
    public init(url: URL, sampleRate: Int, syncEvery: Int = 5) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.syncEvery = syncEvery
        guard FileManager.default.createFile(atPath: url.path, contents: WAVFormat.header(sampleRate: sampleRate, dataBytes: 0))
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    public func append(_ samples: UnsafeBufferPointer<Float>) {
        pending.reserveCapacity(pending.count + samples.count * 2)
        for sample in samples {
            let clamped = sample.isNaN ? 0 : max(-1, min(1, sample))
            let value = Int16(clamped * Float(Int16.max))
            withUnsafeBytes(of: value.littleEndian) { pending.append(contentsOf: $0) }
        }
    }

    public func appendSilence(frames: Int) {
        pending.append(Data(count: frames * 2))
    }

    public func flush() throws {
        guard !pending.isEmpty else { return }
        try handle.write(contentsOf: pending)
        framesWritten += pending.count / 2
        pending.removeAll(keepingCapacity: true)
        try writeSizes()
        flushesSinceSync += 1
        if flushesSinceSync >= syncEvery {
            try handle.synchronize()
            flushesSinceSync = 0
        }
    }

    public func close() throws {
        try flush()
        try handle.synchronize()
        try handle.close()
    }

    private func writeSizes() throws {
        let dataBytes = framesWritten * 2
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: WAVFormat.le32(36 + dataBytes))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: WAVFormat.le32(dataBytes))
        try handle.seekToEnd()
    }
}

public struct WAVAudio: Equatable, Sendable {
    public let sampleRate: Int
    public let samples: [Int16]
    public var duration: TimeInterval { Double(samples.count) / Double(sampleRate) }
}

public enum WAVFormatError: Error, Equatable {
    case notWAV
    case unsupported(String)
}

public enum WAVFormat {
    /// Reads a mono 16-bit file, trusting the file length over a stale data size.
    public static func read(_ url: URL) throws -> WAVAudio {
        let data = try Data(contentsOf: url)
        let layout = try parse(data)
        let samples = data[layout.dataOffset ..< layout.dataOffset + layout.availableBytes / 2 * 2]
            .withUnsafeBytes { Array($0.bindMemory(to: Int16.self)).map(Int16.init(littleEndian:)) }
        return WAVAudio(sampleRate: layout.sampleRate, samples: samples)
    }

    /// Rewrites the header sizes to match the audio actually on disk, dropping a torn final frame.
    /// Returns the recovered duration. Safe to run on a file that was closed cleanly.
    @discardableResult
    public static func repair(_ url: URL) throws -> TimeInterval {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let layout = try parse(data)
        let dataBytes = layout.availableBytes / 2 * 2
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(layout.dataOffset + dataBytes))
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: le32(layout.dataOffset - 8 + dataBytes))
        try handle.seek(toOffset: UInt64(layout.dataOffset - 4))
        try handle.write(contentsOf: le32(dataBytes))
        try handle.synchronize()
        return Double(dataBytes / 2) / Double(layout.sampleRate)
    }

    struct Layout {
        let sampleRate: Int
        let dataOffset: Int
        let availableBytes: Int
    }

    static func parse(_ data: Data) throws -> Layout {
        let bytes = [UInt8](data.prefix(4096))
        guard bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else { throw WAVFormatError.notWAV }
        var offset = 12
        var sampleRate: Int?
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset ..< offset + 4], as: UTF8.self)
            let size = Int(u32(bytes, offset + 4))
            let body = offset + 8
            if id == "fmt " {
                guard body + 16 <= bytes.count else { throw WAVFormatError.notWAV }
                let format = u16(bytes, body), channels = u16(bytes, body + 2), bits = u16(bytes, body + 14)
                guard format == 1, channels == 1, bits == 16 else {
                    throw WAVFormatError.unsupported("format \(format), \(channels) ch, \(bits) bit")
                }
                sampleRate = Int(u32(bytes, body + 4))
            } else if id == "data" {
                guard let sampleRate else { throw WAVFormatError.notWAV }
                return Layout(sampleRate: sampleRate, dataOffset: body, availableBytes: data.count - body)
            }
            offset = body + size + (size & 1)
        }
        throw WAVFormatError.notWAV
    }

    static func header(sampleRate: Int, dataBytes: Int) -> Data {
        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(le32(36 + dataBytes))
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        header.append(le32(16))
        header.append(le16(1))
        header.append(le16(1))
        header.append(le32(sampleRate))
        header.append(le32(sampleRate * 2))
        header.append(le16(2))
        header.append(le16(16))
        header.append(contentsOf: Array("data".utf8))
        header.append(le32(dataBytes))
        return header
    }

    static func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
    static func le16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
}
