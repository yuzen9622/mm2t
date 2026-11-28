import Foundation
import MM2TCore
import Testing
@testable import MM2TLocal

struct WhisperCPUTests {
    @Test func mutedWindowsReturnNoSpeechEvenWithoutModelFiles() async throws {
        let decoder = WhisperCPU(folder: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let muted = (0..<16_000).map { Float($0 % 3 - 1) / 32_768 }
        let text = try await decoder.transcribe(clip: muted, request: .init(languageCode: "zh", hints: [], sampleRate: 16_000))
        #expect(text.isEmpty)
    }

    @Test(arguments: ["Version 3.14", "Open example.com", "café noir", "開會時間 3.14，請確認", "서울 회의"])
    func preservesRecognitionTextAcrossTokenBoundaries(_ source: String) {
        var tokens = WhisperWords()
        for (index, scalar) in source.unicodeScalars.enumerated() {
            Array(String(scalar).utf8).withUnsafeBytes {
                tokens.append(bytes: $0, start: Double(index), end: Double(index + 1))
            }
        }
        #expect(Alignment.joined(tokens.finish()) == source)
    }

    @Test func keepsSplitUTF8AndGroupsEnglishSubwordsWithTheirTimes() {
        var tokens = WhisperWords()
        let han = Array("好".utf8)
        for (bytes, start, end) in [(Array(han.prefix(2)), 0.0, 0.2), (Array(han.suffix(1)), 0.2, 0.4),
                                    (Array(" meet".utf8), 0.6, 0.8), (Array("ing".utf8), 0.8, 1.0)] {
            bytes.withUnsafeBytes { tokens.append(bytes: $0, start: start, end: end) }
        }
        let words = tokens.finish()
        #expect(words == [TimedWord("好", 0, 0.4), TimedWord(" meeting", 0.6, 1)])
    }
}
