import Foundation
import MM2TCore
import MM2TProviders
import MM2TSystem
import Testing
@testable import MM2TApp

@MainActor @Suite struct MeetingListTests {
    @Test func searchesTitlesAndTranscriptsAndDeletesWithTheAudio() async throws {
        let world = try World()
        let budget = try await world.recordedMeeting(title: "預算會議")
        _ = try await world.recordedMeeting(title: "週會")
        let list = world.app.meetings

        await list.reload()
        #expect(Set(list.rows.map(\.title)) == ["預算會議", "週會"])
        #expect(list.rows.allSatisfy { $0.status == .completed })

        list.query = "預算"
        await list.reload()
        #expect(list.rows.map(\.title).contains("預算會議"))
        list.query = "那就這樣"
        await list.reload()
        #expect(list.rows.count == 2, "both transcripts contain the phrase")
        list.query = "不存在的字"
        await list.reload()
        #expect(list.rows.isEmpty)

        let folder = await world.library.audioURL(budget, track: .me).deletingLastPathComponent()
        list.query = ""
        await list.delete(budget.id)
        #expect(list.rows.map(\.title) == ["週會"])
        #expect(!FileManager.default.fileExists(atPath: folder.path), "story 55: recording and text are gone")
    }

    @Test func aMeetingBeingProcessedCannotBeDeleted() async throws {
        let world = try World()
        let gate = Gate<Bool>()
        world.catalog.llm.holds.update { $0["summarize"] = gate }
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "週會", platform: .zoom))
        let stopping = Task { await world.capture.stop() }
        #expect(await eventually { world.queue.activeJob?.state == .running(.summarize) })
        let id = try #require(world.queue.activeJob?.id)

        await world.app.meetings.reload()
        await world.app.meetings.delete(id)
        #expect(try await world.library.meeting(id).id == id)
        #expect(world.app.meetings.rows.first?.status == .processing(.summarize))
        await gate.open(true)
        await stopping.value
    }
}

@MainActor @Suite struct MeetingDetailTests {
    @Test func listRowsPreviewTheSummaryAndWhoSpoke() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        world.app.meetings.meLabel = "我"
        await world.app.meetings.reload()
        let row = try #require(world.app.meetings.rows.first { $0.id == meeting.id })

        #expect(row.headline == "我 拍板預算，我 整理報價。")
        #expect(row.participants.map(\.name) == ["我", "A", "B"])
        #expect(row.participants.map(\.isNamed) == [true, false, false])
    }

    @Test func theFourViewsShowNamesAtDisplayTime() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        let detail = world.detail(meeting.id)
        await detail.load()
        let view = try #require(detail.presentation)

        #expect(view.raw.map(\.speakerName) == ["A", "B", "A", "我"])
        #expect(view.raw[1].isOverlapping, "story 28: B overlapped at 5.5 s")
        #expect(view.cleaned?.first?.text == "整理：大家好今天討論預算")
        #expect(view.digests?.map(\.speakerName) == ["A", "B", "我"])
        #expect(view.digests?.first?.points.first?.text == "A 發言 2 次")
        #expect(view.summary?.decisions.first?.text == "由 我 拍板")
        #expect(view.summary?.actionItems.first?.speakerName == "A")
        let summary = try #require(view.summary)
        let ids = (summary.decisions + summary.discussionPoints + summary.actionItems).map(\.id)
            + (view.digests ?? []).flatMap { $0.points.map(\.id) }
        #expect(Set(ids).count == ids.count, "rows from different sections share one list, so ids must not collide")

        await detail.rename(SpeakerID("r1"), to: .newPerson(name: "王小明"))
        let renamed = try #require(detail.presentation)
        #expect(renamed.raw.first?.speakerName == "王小明")
        #expect(renamed.digests?.first?.points.first?.text == "王小明 發言 2 次", "story 39: no regeneration")
        #expect(renamed.summary?.actionItems.first?.speakerName == "王小明")
        #expect(world.catalog.llm.calls.get.count == 4, "rename made no LLM call")
    }

    @Test func selectingAGeneratedItemJumpsToItsSourceAndPlaysFromThere() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        let playback = FakePlayback()
        let detail = world.detail(meeting.id, playback: playback)
        await detail.load()
        #expect(playback.loaded.map(\.lastPathComponent) == ["mic.wav", "remote.wav"])

        detail.selectedView = .summary
        let decision = try #require(detail.presentation?.summary?.decisions.first?.jump)
        detail.jump(to: decision)

        #expect(detail.selectedView == .raw)
        let source = try #require(detail.presentation?.raw.first { $0.id == detail.focusedUtterance })
        #expect(source.text == "那就這樣決定")
        #expect(playback.isPlaying && playback.currentTime == 30)
    }

    @Test func suggestionsCanBeAcceptedAndSpeakersMergedWhichMarksOutputsStale() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        let detail = world.detail(meeting.id)
        await detail.load()

        let a = try #require(detail.speakers.first { $0.label == "A" })
        #expect(a.suggestion == .inferred(name: "小明", reason: "B 叫了小明，接著 A 回答"))
        await detail.acceptSuggestion(for: a.id)
        #expect(detail.speakers.first { $0.label == "A" }?.displayName == "小明")
        #expect(detail.people.map(\.name) == ["小明"], "story 43: the voiceprint store learned the person")
        #expect(!detail.isStale)

        await detail.merge(SpeakerID("r2"), into: a.id)
        #expect(detail.speakers.filter { !$0.isMe }.map(\.label) == ["A"])
        #expect(detail.isStale, "story 42: the banner shows after a merge")
        #expect(detail.presentation?.raw.filter { $0.speakerName == "小明" }.count == 3)

        await detail.regenerate()
        #expect(!detail.isStale)
        #expect(detail.presentation?.digests?.map(\.speakerName) == ["小明", "我"])
    }

    @Test func renamingToAnExistingPersonReusesThem() async throws {
        let world = try World()
        let existing = try await world.app.voiceprints.addPerson(name: "陳經理")
        let meeting = try await world.recordedMeeting()
        let detail = world.detail(meeting.id)
        await detail.load()
        await detail.rename(SpeakerID("r2"), to: .existing(existing))
        #expect(detail.speakers.first { $0.id == SpeakerID("r2") }?.displayName == "陳經理")
        #expect(await world.app.voiceprints.allPersons().count == 1)
    }

    @Test func editsAreRefusedWhileTheMeetingIsRegenerating() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        let detail = world.detail(meeting.id)
        await detail.load()
        await detail.merge(SpeakerID("r2"), into: SpeakerID("r1"))
        let gate = Gate<Bool>()
        world.catalog.llm.holds.update { $0["cleanTranscript"] = gate }
        let regenerating = Task { await detail.regenerate() }
        #expect(await eventually { world.queue.activeJob?.state == .running(.summarize) })

        #expect(!detail.canEditSpeakers)
        await detail.rename(SpeakerID("r1"), to: .newPerson(name: "不該寫入"))
        #expect(await world.app.voiceprints.allPersons().isEmpty)

        await gate.open(true)
        await regenerating.value
        #expect(detail.canEditSpeakers)
    }

    @Test func reseparationIsOfferedOnlyWhenSeparationFailedAndWarnsAboutEdits() async throws {
        let world = try World()
        let good = try await world.recordedMeeting(title: "正常")
        let goodDetail = world.detail(good.id)
        await goodDetail.load()
        #expect(goodDetail.separationFailure == nil && !goodDetail.canReseparate)

        world.catalog.diarizer.fails.set(true)
        let failed = try await world.recordedMeeting(title: "分群失敗")
        let detail = world.detail(failed.id)
        await detail.load()
        #expect(detail.separationFailure == "LocalModelError()")
        #expect(detail.canReseparate)
        #expect(detail.speakers.first?.isMe == true, "the user's own speech lists them as a speaker")
        let remote = detail.speakers.filter { !$0.isMe }
        #expect(remote.count == 1, "all remote speech under one unnamed speaker")
        #expect(!detail.reseparationDiscardsEdits)

        await detail.rename(remote[0].id, to: .newPerson(name: "遠端"))
        #expect(detail.reseparationDiscardsEdits, "the UI must warn before discarding the name")

        world.catalog.diarizer.fails.set(false)
        await detail.reseparate()
        #expect(detail.speakers.filter { !$0.isMe }.map(\.label) == ["A", "B"])
        #expect(detail.separationFailure == nil && !detail.canReseparate)
        #expect(detail.isStale)
    }

    @Test func exportsEachViewAsMarkdownAndPlainTextWithLocalizedLabels() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        let detail = world.detail(meeting.id)
        await detail.load()

        let raw = try #require(detail.export(.raw, as: .markdown))
        #expect(raw.hasPrefix("# 預算會議: 逐字稿\n"))
        #expect(raw.contains("[00:00:04] **B**: 小明你覺得呢 (重疊)"))
        #expect(raw.contains("[00:00:30] **我**: 那就這樣決定"))

        let summary = try #require(detail.export(.summary, as: .plainText))
        #expect(summary == """
            預算會議: 摘要

            決議

            - 由 我 拍板

            討論重點

            - 預算

            待辦事項

            - 整理報價 (負責人：A)

            """)

        for format in [ExportFormat.markdown, .plainText] {
            let perPerson = try #require(detail.export(.perPerson, as: format))
            #expect(!perPerson.contains("[00:"), "by-person copy carries no timestamps")
            #expect(try #require(detail.export(.summary, as: format)).contains("[00:") == false)
            #expect(try #require(detail.export(.cleaned, as: format)).contains("[00:"), "the cleaned transcript keeps them")
        }

        await detail.merge(SpeakerID("r2"), into: SpeakerID("r1"))
        #expect(detail.export(.perPerson, as: .plainText)?.contains("說話者已變更，請重新產生") == true)
    }
}

@MainActor @Suite struct VoiceprintTests {
    @Test func peopleCanBeRenamedAndDeletedWithTheirVectors() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        let detail = world.detail(meeting.id)
        await detail.load()
        await detail.rename(SpeakerID("r1"), to: .newPerson(name: "Amy"))

        let people = world.app.people
        await people.reload()
        let amy = try #require(people.rows.first)
        #expect(amy.name == "Amy" && amy.voiceprintCount == 1)

        await people.rename(amy.id, to: "  ")
        #expect(people.rows.first?.name == "Amy", "a blank name is ignored")
        await people.rename(amy.id, to: "Amy Chen")
        #expect(people.rows.first?.name == "Amy Chen")

        await people.delete(amy.id)
        #expect(people.rows.isEmpty)
        let stored = try String(contentsOf: world.app.paths.voiceprints, encoding: .utf8)
        #expect(!stored.contains("Amy"), "story 45: removed from disk")
        await detail.load()
        #expect(detail.speakers.first { !$0.isMe }?.displayName == "A", "the meeting falls back to the letter")
    }
}

@MainActor @Suite struct SetupTests {
    @Test func keysGoToTheCredentialStoreAndNeverToUserDefaults() async throws {
        let world = try World(keys: false)
        let field = world.app.setup.field(.geminiAPIKey)
        field.text = "  secret-gemini \n"
        field.save()
        #expect(field.state == .saved)
        #expect(world.credentials.values.get[.geminiAPIKey] == "secret-gemini")
        let persisted = world.defaults.dictionaryRepresentation().values.compactMap { $0 as? Data }
            .map { String(decoding: $0, as: UTF8.self) }
        #expect(!persisted.contains { $0.contains("secret-gemini") })

        field.text = ""
        field.save()
        #expect(world.credentials.values.get[.geminiAPIKey] == nil, "clearing the field deletes the key")
    }

    @Test func validationReportsTheVerdictAndTheTokenNeedsAServer() async throws {
        let world = try World(keys: false)
        let gemini = world.app.setup.field(.geminiAPIKey)
        gemini.text = "bad"
        await gemini.validate()
        #expect(gemini.state == .checked(.rejected("Gemini API Key 無效")))

        let token = world.app.setup.field(.selfHostedToken)
        token.text = "t0k3n"
        await token.validate()
        #expect(token.state == .needsServerURL)

        let url = try #require(AppSettings.selfHostedURL(from: "https://gpu.example.ts.net"))
        world.app.settings.settings.selfHostedURL = url
        await token.validate()
        #expect(token.state == .checked(.valid))
        #expect(world.validator.requests.get.last == .selfHosted(url: url, token: "t0k3n"))
    }

    @Test func permissionsAndModelDownloadFeedOnboarding() async throws {
        let world = try World()
        world.catalog.modelsDownloaded.set(false)
        world.permissions.mic.set(.notDetermined)
        let setup = world.app.setup
        setup.refresh()
        #expect(setup.microphone == .notDetermined)
        #expect(setup.accessibility == .denied)
        #expect(setup.models == .notDownloaded)
        #expect(setup.issues == [.diarizationModelsMissing])

        await world.permissions.answer.open(true)
        await setup.requestMicrophone()
        #expect(setup.microphone == .granted)

        await setup.downloadModels()
        #expect(setup.models == .downloaded)
        #expect(setup.issues.isEmpty)
    }

    @Test func settingsSurviveARelaunchAndOldBlobsStillLoad() throws {
        let defaults = UserDefaults(suiteName: "mm2t-settings-\(UUID().uuidString)")!
        let first = SettingsStore(defaults: defaults)
        first.settings.transcriptionOrder = [.selfHosted, .cloud]
        first.settings.addVocabulary("mm2t", source: .manual)
        first.settings.hasCompletedOnboarding = true
        #expect(SettingsStore(defaults: defaults).settings == first.settings)

        defaults.set(Data(#"{"vocabulary":["舊"]}"#.utf8), forKey: SettingsStore.key)
        let migrated = SettingsStore(defaults: defaults).settings
        #expect(migrated.vocabulary == ["舊"])
        #expect(migrated.transcriptionOrder == [.cloud] && migrated.diarizationOrder == [.local, .transcription])
        #expect(migrated.hidesFromScreenCapture)

        #expect(AppSettings.selfHostedURL(from: "gpu:8000") == nil)
        #expect(AppSettings.selfHostedURL(from: "ftp://gpu") == nil)
    }

    @Test func appLanguageIsReadFromTheAppsOwnDomainOnly() throws {
        let suite = "mm2t-language-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppLanguage.current(in: defaults, domain: suite) == .system)
        AppLanguage.traditionalChinese.save(in: defaults)
        #expect(defaults.stringArray(forKey: AppLanguage.key) == ["zh-Hant"])
        #expect(AppLanguage.current(in: defaults, domain: suite) == .traditionalChinese)
        AppLanguage.english.save(in: defaults)
        #expect(AppLanguage.current(in: defaults, domain: suite) == .english)
        AppLanguage.system.save(in: defaults)
        #expect(AppLanguage.current(in: defaults, domain: suite) == .system)
    }
}
