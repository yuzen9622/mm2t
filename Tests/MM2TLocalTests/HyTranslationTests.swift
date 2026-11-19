import Foundation
import Testing
@testable import MM2TLocal

@Suite struct HyTranslationTests {
    @Test func absentModelDoesNotFetchDuringTranslation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let models = HyTranslationModels(in: root)
        #expect(!models.isDownloaded)
        let translator = HyCaptionTranslator(models: models)
        #expect(try await translator.translate("Already English", through: ["en", "en"]) == "Already English")
        await #expect(throws: (any Error).self) { try await translator.translate("Hello", through: ["en", "ja"]) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    // Opt in with a models root on a volume with space for the 1.13 GB official GGUF.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MM2T_HY_TEST_MODELS"] != nil))
    func downloadsAndTranslatesSeveralCaptions() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["MM2T_HY_TEST_MODELS"])
        let models = HyTranslationModels(in: URL(fileURLWithPath: root))
        try await models.download { _ in }
        #expect(models.isDownloaded)
        #expect(try TranslationModels.sha256(of: models.file) == HyTranslationModels.sha256)
        let translator = HyCaptionTranslator(models: models)
        let meeting = try await translator.translate("我們明天開會。", through: ["zh_hant", "en"]).lowercased()
        #expect(meeting.contains("tomorrow") && meeting.contains("meet"))
        let train = try await translator.translate("The train leaves at nine.", through: ["en", "zh_hant"])
        #expect(train.contains("車") && (train.contains("九") || train.contains("9")))
        let thanks = try await translator.translate("非常感謝。", through: ["zh_hant", "en", "cs"]).lowercased()
        #expect(thanks.contains("děk") || thanks.contains("dík"))
        print("Hy-MT2 smoke: \(meeting) | \(train) | \(thanks)")
    }
}
