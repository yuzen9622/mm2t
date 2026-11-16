import Foundation
import MM2TCore
import Testing
@testable import MM2TApp

@MainActor
@Suite struct LiveTranslationTests {
    /// Captions translating into `target` with a fake translator, a clock that moves only when
    /// told and partial waits the test releases by hand.
    @MainActor struct Harness {
        let captions: LiveCaptions
        let translator = FakeTranslator()
        let clock = Box(Date(timeIntervalSince1970: 0))
        let waits = Box<[Duration]>([])
        let gate = Box(Gate<Bool>())

        init(target: CaptionLanguage = .traditionalChinese) {
            let clock = clock
            captions = LiveCaptions(now: { clock.get })
            let waits = waits
            let gate = gate
            captions.translate(with: translator, to: target, sleep: { duration in
                waits.update { $0.append(duration) }
                _ = await gate.get.wait()
            })
        }

        func releaseWait() async {
            let current = gate.get
            gate.set(Gate<Bool>())
            await current.open(true)
        }

        var texts: [String] { translator.calls.get.map(\.text) }
    }

    @Test func aSegmentAlreadyInTheTargetLanguageIsNotTranslated() async throws {
        let harness = Harness(target: .traditionalChinese)
        harness.captions.receive(.final("大家好，今天討論預算。"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.texts.isEmpty)
        let segment = try #require(harness.captions.segments.first)
        #expect(segment.translation == nil)
        #expect(harness.captions.mainText(of: segment) == "大家好，今天討論預算。")
    }

    @Test func anEnglishSegmentIsTranslatedIntoTraditionalChinese() async throws {
        let harness = Harness(target: .traditionalChinese)
        harness.translator.answers.set(["Let's talk later.": "我们后面再说。"])
        harness.captions.receive(.final("Let's talk later."))
        #expect(await eventually { harness.captions.segments.first?.translation != nil })
        let segment = harness.captions.segments[0]
        #expect(segment.translation == "我們後面再說。", "Chinese output is converted to Traditional")
        #expect(harness.captions.mainText(of: segment) == "我們後面再說。")
        #expect(harness.translator.calls.get == [.init(text: "Let's talk later.", source: .english, target: .traditionalChinese)])
    }

    @Test func intoEnglishOnlyChineseIsTranslated() async throws {
        let harness = Harness(target: .english)
        harness.captions.receive(.final("We agreed."))
        harness.captions.receive(.final("下週再確認。"))
        harness.captions.receive(.final("2026."))
        #expect(await eventually { harness.captions.segments[1].translation == "⟨下週再確認。⟩" })
        #expect(harness.translator.calls.get == [.init(text: "下週再確認。", source: .traditionalChinese, target: .english)])
        #expect(harness.captions.segments[0].translation == nil)
        #expect(harness.captions.segments[2].translation == nil, "digits and punctuation are left as they are")
    }

    @Test func resultsAttachToTheirOwnSegmentWhateverOrderTheyReturnIn() async throws {
        let harness = Harness()
        harness.translator.holds.set(true)
        harness.captions.receive(.final("First point."))
        harness.captions.receive(.final("Second point."))
        #expect(await eventually { harness.translator.held == ["First point.", "Second point."] })
        #expect(harness.texts == ["First point.", "Second point."], "sent in the order they settled")
        let ids = harness.captions.segments.map(\.id)
        #expect(harness.captions.segments.allSatisfy { harness.captions.mainText(of: $0) == nil }, "nothing shown until translated")

        await harness.translator.release("Second point.")
        #expect(await eventually { harness.captions.segments[1].translation == "⟨Second point.⟩" })
        #expect(harness.captions.segments[0].translation == nil)
        #expect(harness.captions.awaitingTranslation == [ids[0]])

        await harness.translator.release("First point.")
        #expect(await eventually { harness.captions.segments[0].translation == "⟨First point.⟩" })
        #expect(harness.captions.segments[1].translation == "⟨Second point.⟩")
        #expect(harness.captions.awaitingTranslation.isEmpty)
    }

    @Test func aPartialTranslationIsDroppedWhenThePartialChanges() async throws {
        let harness = Harness()
        harness.translator.holds.set(true)
        harness.captions.receive(.partial("We meet"))
        #expect(await eventually { harness.translator.held == ["We meet"] })
        #expect(harness.captions.isPartialAwaitingTranslation)
        #expect(harness.captions.partialMainText.isEmpty)

        harness.captions.receive(.partial("We meet on Monday"))
        await harness.translator.release("We meet")
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.captions.partialTranslation == nil, "never a translation of older words under newer ones")
        #expect(harness.captions.isPartialAwaitingTranslation)
    }

    @Test func aPartialTranslationIsDroppedWhenItsSegmentFinishes() async throws {
        let harness = Harness()
        harness.translator.holds.set(true)
        harness.captions.receive(.partial("See you"))
        #expect(await eventually { harness.translator.held == ["See you"] })
        harness.captions.receive(.final("See you tomorrow."))
        #expect(harness.captions.partialTranslation == nil)
        #expect(!harness.captions.isPartialAwaitingTranslation)
        await harness.translator.release("See you")
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.captions.partialTranslation == nil)
        #expect(await eventually { harness.translator.held == ["See you tomorrow."] })
        await harness.translator.release("See you tomorrow.")
        #expect(await eventually { harness.captions.segments.first?.translation == "⟨See you tomorrow.⟩" })
    }

    @Test func thePartialIsTranslatedAtMostEveryFourHundredMillisecondsAndOnlyWhenItChanged() async throws {
        let harness = Harness()
        harness.captions.receive(.partial("The budget"))
        #expect(await eventually { harness.captions.partialTranslation == "⟨The budget⟩" })
        #expect(harness.texts == ["The budget"])

        harness.clock.set(Date(timeIntervalSince1970: 0.1))
        harness.captions.receive(.partial("The budget is"))
        harness.captions.receive(.partial("The budget is final"))
        #expect(await eventually { harness.waits.get.count == 1 })
        #expect(harness.waits.get == [.milliseconds(300)], "waits out the rest of the 400 ms")
        #expect(harness.texts == ["The budget"])

        harness.clock.set(Date(timeIntervalSince1970: 0.4))
        await harness.releaseWait()
        #expect(await eventually { harness.captions.partialTranslation == "⟨The budget is final⟩" })
        #expect(harness.texts == ["The budget", "The budget is final"], "only the newest words, once")

        // A revision back to words already translated reuses that answer without a new call.
        harness.clock.set(Date(timeIntervalSince1970: 1))
        harness.captions.receive(.partial("The budget is fina"))
        #expect(await eventually { harness.captions.partialTranslation == "⟨The budget is fina⟩" })
        #expect(harness.texts.count == 3)
    }

    @Test func aFailureLeavesTheCaptionsAsTheyAreAndTheStatusUntouched() async throws {
        let harness = Harness()
        harness.captions.set(.live)
        harness.translator.failing.set(["Hello everyone."])
        harness.captions.receive(.final("Hello everyone."))
        harness.captions.receive(.final("大家好。"))
        #expect(await eventually { harness.captions.awaitingTranslation.isEmpty && !harness.translator.calls.get.isEmpty })
        let segment = harness.captions.segments[0]
        #expect(segment.translation == nil)
        #expect(harness.captions.mainText(of: segment) == "Hello everyone.", "shown in its own words")
        #expect(harness.captions.segments.map(\.text) == ["Hello everyone.", "大家好。"])
        #expect(harness.captions.status == .live)
    }

    @Test func stoppingDropsTheTranslatorAndEveryTranslation() async throws {
        let harness = Harness()
        harness.captions.receive(.final("Done."))
        #expect(await eventually { harness.captions.segments.first?.translation != nil })
        harness.captions.clear()
        #expect(harness.captions.translationTarget == nil)
        harness.captions.receive(.final("After."))
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.texts == ["Done."], "nothing is translated once the recording's captions are cleared")
    }

    @Test func processingIgnoresTheTranslationSetting() throws {
        var settings = AppSettings()
        let before = settings.forProcessing
        settings.captionTranslation = .english
        #expect(settings.forProcessing == before)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.captionTranslation == .english)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).captionTranslation == .off)
    }

    // MARK: Through the app

    @Test func turningTranslationOnDownloadsTheModels() async throws {
        let world = try World()
        #expect(world.app.setup.translationModels == .notDownloaded)
        await world.app.setCaptionTranslation(.traditionalChinese)
        #expect(world.app.settings.settings.captionTranslation == .traditionalChinese)
        #expect(world.app.setup.translationModels == .downloaded)
        #expect(world.catalog.translationDownloaded.get)
    }

    @Test func aRecordingTranslatesItsCaptionsOnceTheModelsAreThere() async throws {
        let world = try World()
        world.app.settings.settings.liveCaptions = true
        world.app.settings.settings.captionTranslation = .english
        world.catalog.translationDownloaded.set(true)
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "週會", platform: .zoom))
        #expect(await eventually { world.capture.captions.status == .live })
        #expect(world.capture.captions.translationTarget == .english)
        world.catalog.streaming.last?.say(.final("下週再確認。"))
        #expect(await eventually { world.capture.captions.segments.first?.translation == "⟨下週再確認。⟩" })
        await world.capture.stop()
        #expect(world.capture.captions.translationTarget == nil)
        #expect(world.capture.captions.segments.isEmpty)
    }

    @Test func withoutTheModelsCaptionsRunUntranslated() async throws {
        let world = try World()
        world.app.settings.settings.liveCaptions = true
        world.app.settings.settings.captionTranslation = .english
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "週會", platform: .zoom))
        #expect(await eventually { world.capture.captions.status == .live })
        #expect(world.capture.captions.translationTarget == nil)
        world.catalog.streaming.last?.say(.final("下週再確認。"))
        #expect(await eventually { world.capture.captions.segments.count == 1 })
        #expect(world.catalog.translator.calls.get.isEmpty)
        await world.capture.stop()
    }
}
