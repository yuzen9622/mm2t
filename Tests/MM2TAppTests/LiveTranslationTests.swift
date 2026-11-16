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

    @Test func onlyTheSettledPartOfAPartialIsSentAndItsTranslationIsNeverBlanked() async throws {
        let harness = Harness()
        harness.captions.receive(.partial("We meet on Monday"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.texts.isEmpty, "no clause boundary yet and too few words")
        #expect(harness.captions.partialMainText.isEmpty)

        harness.captions.receive(.partial("We meet on Monday, at ten"))
        #expect(await eventually { harness.captions.partialTranslation == "⟨We meet on Monday,⟩" })
        #expect(harness.texts == ["We meet on Monday,"], "the unfinished clause stays out")

        harness.clock.set(Date(timeIntervalSince1970: 1))
        harness.translator.holds.set(true)
        harness.captions.receive(.partial("We meet on Monday, at ten, in room"))
        #expect(await eventually { harness.translator.held == ["We meet on Monday, at ten,"] })
        harness.captions.receive(.partial("We meet on Monday, at ten, in room four"))
        #expect(harness.captions.partialTranslation == "⟨We meet on Monday,⟩", "the shown one stays while the next is out")
        #expect(harness.captions.partialMainText == "⟨We meet on Monday,⟩")

        await harness.translator.release("We meet on Monday, at ten,")
        #expect(await eventually { harness.captions.partialTranslation == "⟨We meet on Monday, at ten,⟩" })
        #expect(harness.texts == ["We meet on Monday,", "We meet on Monday, at ten,"])
    }

    @Test func aFinishedSegmentKeepsItsPartialTranslationUntilItsOwnReplacesItInPlace() async throws {
        let harness = Harness()
        harness.captions.receive(.partial("See you tomorrow, then"))
        #expect(await eventually { harness.captions.partialTranslation == "⟨See you tomorrow,⟩" })

        harness.translator.holds.set(true)
        harness.captions.receive(.final("See you tomorrow, then."))
        let id = try #require(harness.captions.segments.first?.id)
        #expect(harness.captions.partialTranslation == nil)
        #expect(harness.captions.displaySegments.map(\.text) == ["⟨See you tomorrow,⟩"], "never hidden while it waits")
        #expect(harness.captions.awaitingTranslation == [id])

        #expect(await eventually { harness.translator.held == ["See you tomorrow, then."] })
        await harness.translator.release("See you tomorrow, then.")
        #expect(await eventually { harness.captions.displaySegments.map(\.text) == ["⟨See you tomorrow, then.⟩"] })
        #expect(harness.captions.provisionalTranslations.isEmpty)
    }

    @Test func aPartialResultThatArrivesAfterItsSegmentSettledStandsInForIt() async throws {
        let harness = Harness()
        harness.translator.holds.set(true)
        harness.captions.receive(.partial("Wait, what"))
        #expect(await eventually { harness.translator.held == ["Wait,"] })
        harness.captions.receive(.final("Wait, what?"))
        #expect(harness.captions.displaySegments.isEmpty, "nothing was shown for it yet")

        await harness.translator.release("Wait,")
        #expect(await eventually { harness.captions.displaySegments.map(\.text) == ["⟨Wait,⟩"] })
        #expect(harness.captions.partialTranslation == nil, "it belongs to the settled segment, not the next partial")
        #expect(await eventually { harness.translator.held == ["Wait, what?"] })
        await harness.translator.release("Wait, what?")
        #expect(await eventually { harness.captions.displaySegments.map(\.text) == ["⟨Wait, what?⟩"] })
    }

    @Test func partialSendsAreAtLeastAQuarterSecondApart() async throws {
        let harness = Harness()
        harness.captions.receive(.partial("One, two"))
        #expect(await eventually { harness.captions.partialTranslation == "⟨One,⟩" })

        harness.clock.set(Date(timeIntervalSince1970: 0.1))
        harness.captions.receive(.partial("One, two, three"))
        harness.captions.receive(.partial("One, two, three, four"))
        #expect(await eventually { harness.waits.get.count == 1 })
        #expect(harness.waits.get == [.milliseconds(150)], "waits out the rest of the 250 ms")
        #expect(harness.texts == ["One,"])

        harness.clock.set(Date(timeIntervalSince1970: 0.25))
        await harness.releaseWait()
        #expect(await eventually { harness.captions.partialTranslation == "⟨One, two, three,⟩" })
        #expect(harness.texts == ["One,", "One, two, three,"], "only the newest settled part, once")
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

    @Test func aFailedFinalTranslationKeepsWhatWasShown() async throws {
        let harness = Harness()
        harness.captions.receive(.partial("Budget first, then"))
        #expect(await eventually { harness.captions.partialTranslation == "⟨Budget first,⟩" })
        harness.translator.failing.set(["Budget first, then hiring."])
        harness.captions.receive(.final("Budget first, then hiring."))
        #expect(await eventually { harness.captions.awaitingTranslation.isEmpty && harness.texts.count == 2 })
        let segment = harness.captions.segments[0]
        #expect(harness.captions.shownTranslation(of: segment) == "⟨Budget first,⟩", "a translation once shown stays")
        #expect(harness.captions.mainText(of: segment) == "⟨Budget first,⟩")
    }

    @Test func aSegmentInTheTargetLanguageShowsAsItIs() async throws {
        let harness = Harness()
        harness.captions.receive(.partial("大家好，今天"))
        #expect(harness.captions.partialMainText == "大家好，今天")
        harness.captions.receive(.final("大家好，今天開始。"))
        #expect(harness.captions.displaySegments.map(\.text) == ["大家好，今天開始。"])
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.texts.isEmpty)
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
