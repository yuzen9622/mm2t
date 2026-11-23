import Foundation
import MM2TCore
import MM2TSystem
import Testing
@testable import MM2TApp

@MainActor
@Suite struct LiveCaptionsTests {
    // MARK: The caption model

    @Test func aPartialReplacesThePreviousPartial() {
        let captions = LiveCaptions()
        captions.receive(.partial("大家"))
        captions.receive(.partial("大家好今天"))
        #expect(captions.partial == "大家好今天")
        #expect(captions.segments.isEmpty)
    }

    @Test func aFinalAppendsASegmentAndClearsThePartial() {
        let captions = LiveCaptions()
        captions.receive(.partial("大家好"))
        captions.receive(.final("大家好，今天討論預算。"))
        #expect(captions.partial.isEmpty)
        #expect(captions.segments.map(\.text) == ["大家好，今天討論預算。"])
        #expect(captions.segments[0].translation == nil)
        captions.receive(.final("  "))
        #expect(captions.segments.count == 1, "an empty commit adds nothing")
    }

    @Test func simplifiedChineseIsNeverShown() {
        let captions = LiveCaptions()
        captions.receive(.partial("简体说话"))
        #expect(captions.partial == "簡體說話")
        captions.receive(.final("后面再说"))
        #expect(captions.segments.last?.text == "後面再說")
    }

    @Test func onlyTheLastTwoHundredSegmentsAreKept() {
        let captions = LiveCaptions()
        for index in 0..<205 { captions.receive(.final("第\(index)句")) }
        #expect(captions.segments.count == LiveCaptions.limit)
        #expect(captions.segments.first?.text == "第5句")
        #expect(captions.segments.last?.text == "第204句")
        #expect(Set(captions.segments.map(\.id)).count == LiveCaptions.limit)
    }

    @Test func segmentsLessThanTwoSecondsApartFormOneParagraph() {
        let clock = Box(Date(timeIntervalSince1970: 0))
        let captions = LiveCaptions(now: { clock.get })
        func at(_ seconds: Double, _ event: StreamingTranscriptEvent) {
            clock.set(Date(timeIntervalSince1970: seconds))
            captions.receive(event)
        }
        at(0, .partial("一"))
        at(2, .final("一"))
        at(3, .partial("二"))
        at(4, .final("二"))
        at(9, .partial("三"))
        at(10, .final("三"))
        #expect(captions.paragraphs.map { $0.map(\.text) } == [["一", "二"], ["三"]])
    }

    // MARK: What the bar fades in

    private func segment(_ id: Int, _ text: String) -> LiveCaptions.Segment {
        LiveCaptions.Segment(id: id, text: text, started: .distantPast, ended: .distantPast)
    }

    @Test func aRevisedPartialFadesInOnlyItsChangedTail() {
        var arrivals = CaptionArrivals()
        let t0 = Date(timeIntervalSince1970: 0), t1 = t0.addingTimeInterval(1), t2 = t0.addingTimeInterval(2)
        #expect(arrivals.update(segments: [], partial: "We meet", now: t0)
            == [CaptionRun(text: "We meet", arrived: t0, isPartial: true)])
        #expect(arrivals.update(segments: [], partial: "We meet on Monday", now: t1)
            == [CaptionRun(text: "We meet", arrived: t0, isPartial: true), CaptionRun(text: " on Monday", arrived: t1, isPartial: true)])
        // A revision keeps only the unchanged beginning's time.
        #expect(arrivals.update(segments: [], partial: "We met", now: t2)
            == [CaptionRun(text: "We me", arrived: t0, isPartial: true), CaptionRun(text: "t", arrived: t2, isPartial: true)])
    }

    @Test func aSettledSegmentKeepsItsTimesAndCJKJoinsWithoutSpaces() {
        var arrivals = CaptionArrivals()
        let t0 = Date(timeIntervalSince1970: 0), t1 = t0.addingTimeInterval(1), t2 = t0.addingTimeInterval(2)
        _ = arrivals.update(segments: [], partial: "大家好", now: t0)
        #expect(arrivals.update(segments: [segment(0, "大家好。")], partial: "", now: t1)
            == [CaptionRun(text: "大家好", arrived: t0, isPartial: false), CaptionRun(text: "。", arrived: t1, isPartial: false)])
        #expect(arrivals.update(segments: [segment(0, "大家好。")], partial: "今天", now: t2).last
            == CaptionRun(text: "今天", arrived: t2, isPartial: true))
        var latin = CaptionArrivals()
        #expect(latin.update(segments: [segment(0, "Hello.")], partial: "Next", now: t0).map(\.text) == ["Hello.", " Next"])
    }

    @Test func theBarKeepsOnlyRecentSegments() {
        let segments = (0..<10).map { segment($0, String(repeating: "字", count: 100)) }
        #expect(CaptionArrivals.recent(segments).map(\.id) == [8, 9])
        #expect(CaptionArrivals.recent([segment(0, String(repeating: "字", count: 500))]).count == 1)
    }

    @Test func barOffsetsSurviveASettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.captionBarOffsets["69733382"] = CaptionBarOffset(x: -120, y: 48)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.captionBarOffsets == settings.captionBarOffsets)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).liveCaptions == false)
    }

    // MARK: The stream

    /// A stream wired to a fake service, with backoff waits the test releases by hand.
    @MainActor struct Harness {
        let captions: LiveCaptions
        let provider = FakeStreamingSTT()
        let stream: CaptionStream
        let audio: AsyncStream<[Float]>.Continuation
        let waits = Box<[Duration]>([])
        let gate = Box(Gate<Bool>())

        init() async {
            let captions = LiveCaptions()
            self.captions = captions
            let (audioStream, audio) = AsyncStream.makeStream(of: [Float].self)
            self.audio = audio
            let waits = waits
            let gate = gate
            stream = CaptionStream(provider: provider, languageCode: "zh", hints: ["王小明"], captions: captions,
                                   sleep: { duration in
                                       waits.update { $0.append(duration) }
                                       _ = await gate.get.wait()
                                   })
            await stream.start(audio: audioStream, sampleRate: 16_000)
        }

        func releaseWait() async {
            let current = gate.get
            gate.set(Gate<Bool>())
            await current.open(true)
        }
    }

    @Test func opensOneSessionWithTheSettingsLanguageAndHints() async throws {
        let harness = await Harness()
        #expect(await eventually { harness.provider.last != nil && harness.captions.status == .live })
        let request = try #require(harness.provider.requests.get.first)
        #expect(request.languageCode == "zh")
        #expect(request.hints == ["王小明"])
        #expect(request.sampleRate == 16_000)
        #expect(request.previousText == nil)
    }

    @Test func audioLeavesInChunksOfAtMostAQuarterSecond() async throws {
        let harness = await Harness()
        #expect(await eventually { harness.captions.status == .live })
        harness.audio.yield([Float](repeating: 0.1, count: 800))
        harness.audio.yield([Float](repeating: 0.1, count: 16_000))
        let session = try #require(harness.provider.last)
        // 16,800 samples leave as four quarter-second chunks; the last 50 ms wait for more.
        #expect(await eventually { session.sent.get.map(\.count) == [4_000, 4_000, 4_000, 4_000] })
    }

    @Test func aDroppedSessionReconnectsKeepingEarlierSegments() async throws {
        let harness = await Harness()
        #expect(await eventually { harness.captions.status == .live })
        let first = try #require(harness.provider.last)
        first.say(.final("第一句。"))
        first.say(.partial("第二"))
        #expect(await eventually { harness.captions.partial == "第二" })

        first.drop()
        #expect(await eventually { harness.captions.status == .reconnecting })
        #expect(harness.captions.segments.map(\.text) == ["第一句。", "第二"], "the unfinished words are kept as heard")
        #expect(await eventually { harness.waits.get == [.seconds(1)] })
        // Audio from the gap is dropped, not replayed.
        harness.audio.yield([Float](repeating: 0.1, count: 3_200))

        await harness.releaseWait()
        #expect(await eventually { harness.provider.sessions.get.count == 2 && harness.captions.status == .live })
        #expect(harness.provider.requests.get.last?.previousText == "第二")
        #expect(first.sent.get.isEmpty)
        #expect(harness.provider.last?.sent.get.isEmpty == true)
        harness.provider.last?.say(.final("第三句。"))
        #expect(await eventually { harness.captions.segments.count == 3 })
    }

    @Test func failuresInARowBackOffOneTwoFiveThenTen() async throws {
        let harness = await Harness()
        #expect(await eventually { harness.captions.status == .live })
        harness.provider.openFailures.set(Array(repeating: .unreachable("offline"), count: 4))
        harness.provider.last?.drop()
        for count in 1...5 {
            #expect(await eventually { harness.waits.get.count == count })
            await harness.releaseWait()
        }
        #expect(harness.waits.get == [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(10)])
        #expect(await eventually { harness.captions.status == .live })
    }

    @Test func aFailureOnlyTheUserCanFixMakesCaptionsUnavailable() async throws {
        let harness = await Harness()
        #expect(await eventually { harness.captions.status == .live })
        harness.provider.last?.drop(TranscriptionError.failed("ElevenLabs API Key is invalid"))
        #expect(await eventually { harness.captions.status == .unavailable("ElevenLabs API Key is invalid") })
        #expect(harness.waits.get.isEmpty)
        #expect(harness.provider.sessions.get.count == 1)
    }

    // MARK: Through the capture controller

    @Test func captionsOffOpensNothing() async throws {
        let world = try World()
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "週會", platform: .zoom))
        try await Task.sleep(for: .milliseconds(20))
        #expect(world.catalog.streaming.requests.get.isEmpty)
        #expect(await world.recorder.last?.audioRequests == 0)
        #expect(world.capture.captions.status == .off)
        await world.capture.stop()
    }

    @Test func withNoTranscriptionSourceSetUpCaptionsOpenNothing() async throws {
        let world = try World(keys: false)
        world.app.settings.settings.liveCaptions = true
        world.app.settings.settings.localCaptionModel = .breeze
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "週會", platform: .zoom))
        try await Task.sleep(for: .milliseconds(20))
        #expect(world.catalog.streaming.requests.get.isEmpty)
        #expect(world.catalog.selfHostedStreaming.requests.get.isEmpty)
        #expect(world.catalog.localStreaming.requests.get.isEmpty)
        #expect(world.capture.captions.status == .off)
        await world.capture.stop()
    }

    @Test(arguments: [false, true]) func changingPostMeetingServiceDoesNotStopElevenLabsCaptions(migrated: Bool) async throws {
        let world = try World()
        if migrated {
            world.app.settings.settings = try JSONDecoder().decode(AppSettings.self, from:
                Data(#"{"transcriptionOrder":["cloud"]}"#.utf8))
        }
        world.app.settings.settings.liveCaptions = true
        #expect(world.app.settings.settings.effectiveCaptionModel == nil)
        let expected = migrated ? [TranscriptionSource.cloud] : [.local, .cloud]
        #expect(world.app.settings.settings.captionSources == expected)
        world.app.settings.settings.transcriptionService = .mm2t
        #expect(world.app.settings.settings.captionSources == expected)
        let saved = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(world.app.settings.settings))
        #expect(saved.captionSources == expected)
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "週會", platform: .zoom))
        #expect(await eventually { world.capture.captions.status == .live })
        #expect(world.catalog.streaming.sessions.get.count == 1)
        await world.capture.stop()
    }

    @Test func aSavedServerSelectionKeepsCaptionsOnThatServerEvenWithAnElevenLabsKey() async throws {
        let world = try World()
        world.app.settings.settings = try JSONDecoder().decode(AppSettings.self, from: Data(
            #"{"transcriptionService":"server","selfHostedURL":"https://speech.example","liveCaptions":true}"#.utf8))
        world.app.settings.settings.transcriptionService = .mm2t
        let saved = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(world.app.settings.settings))
        world.app.settings.settings = saved
        #expect(saved.captionSources == [.local, .selfHosted])
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "週會", platform: .zoom))
        #expect(await eventually { world.capture.captions.status == .live })
        #expect(world.catalog.selfHostedStreaming.sessions.get.count == 1)
        #expect(world.catalog.streaming.requests.get.isEmpty)
        await world.capture.stop()
    }

    @Test func captionsFollowTheTranscriptionOrderStartingWithTheServer() async throws {
        let world = try World()
        world.app.settings.settings = try JSONDecoder().decode(AppSettings.self, from:
            Data(#"{"transcriptionOrder":["selfHosted","cloud","local"],"liveCaptions":true}"#.utf8))
        world.app.settings.settings.localCaptionModel = .breeze
        world.app.settings.settings.selfHostedURL = URL(string: "http://gpu.tailnet:8123")
        world.catalog.offlineDownloaded[.transcription]!.set(true)
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "週會", platform: .zoom))
        #expect(await eventually { world.capture.captions.status == .live })
        #expect(world.catalog.selfHostedURLs.get.contains(URL(string: "http://gpu.tailnet:8123")!))
        #expect(world.catalog.selfHostedStreaming.sessions.get.count == 1)
        #expect(world.catalog.streaming.requests.get.isEmpty)
        await world.capture.stop()
    }

    @Test func anOfflineServerFallsToElevenLabsThenThisMac() async throws {
        let world = try World()
        world.app.settings.settings = try JSONDecoder().decode(AppSettings.self, from:
            Data(#"{"transcriptionOrder":["selfHosted","cloud","local"],"liveCaptions":true}"#.utf8))
        world.app.settings.settings.localCaptionModel = .breeze
        world.app.settings.settings.selfHostedURL = URL(string: "http://gpu.tailnet:8123")
        world.catalog.offlineDownloaded[.transcription]!.set(true)
        world.catalog.selfHostedStreaming.openFailures.set([.unreachable("offline")])
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "週會", platform: .zoom))
        #expect(await eventually { world.capture.captions.status == .live })
        #expect(world.catalog.streaming.sessions.get.count == 1)
        #expect(world.catalog.localStreaming.requests.get.isEmpty)
        await world.capture.stop()
    }

    @Test func withoutAnElevenLabsKeyCaptionsRunOnThisMac() async throws {
        let world = try World(keys: false)
        world.app.settings.settings.liveCaptions = true
        world.app.settings.settings.localSpeechModel = .breeze
        world.catalog.offlineDownloaded[.transcription]!.set(true)
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "週會", platform: .zoom))
        #expect(await eventually { world.capture.captions.status == .live })
        #expect(world.catalog.localStreaming.sessions.get.count == 1)
        #expect(world.catalog.streaming.requests.get.isEmpty)
        await world.capture.stop()
    }

    @Test func pausingClosesTheSessionAndStopsSending() async throws {
        let world = try World()
        world.app.settings.settings.liveCaptions = true
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "週會", platform: .zoom))
        let streaming = world.catalog.streaming
        #expect(await eventually { world.capture.captions.status == .live })
        #expect(world.catalog.keysUsed.get.contains("captions:eleven-key"))
        let recording = try #require(world.recorder.last)
        let first = try #require(streaming.last)
        await recording.speak()
        #expect(await eventually { first.sentSeconds == 0.25 })

        await world.capture.pause()
        #expect(first.closed.get)
        await recording.speak()
        try await Task.sleep(for: .milliseconds(20))
        #expect(first.sentSeconds == 0.25)
        #expect(streaming.sessions.get.count == 1)

        await world.capture.resume()
        #expect(await eventually { streaming.sessions.get.count == 2 && world.capture.captions.status == .live })
        await recording.speak()
        #expect(await eventually { streaming.last?.sentSeconds == 0.25 })
        await world.capture.stop()
    }

    @Test func stoppingClosesTheSessionAndClearsEverything() async throws {
        let world = try World()
        world.app.settings.settings.liveCaptions = true
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "週會", platform: .zoom))
        #expect(await eventually { world.capture.captions.status == .live })
        let session = try #require(world.catalog.streaming.last)
        session.say(.final("大家好。"))
        session.say(.partial("今天"))
        #expect(await eventually { world.capture.captions.partial == "今天" })

        let gate = Gate<Bool>()
        session.discardGate.set(gate)
        let stopping = Task { await world.capture.stop() }
        #expect(await eventually { world.capture.lastSavedMeeting != nil && world.capture.state == .idle })
        #expect(!session.closed.get)
        await gate.open(true)
        await stopping.value
        #expect(await eventually { session.closed.get })
        #expect(world.capture.captions.segments.isEmpty)
        #expect(world.capture.captions.partial.isEmpty)
        #expect(world.capture.captions.status == .off)
    }

    @Test func aCaptionFailureLeavesTheRecordAsItWouldBeWithout() async throws {
        let plain = try World()
        let expected = try await plain.recordedMeeting()

        let world = try World()
        world.app.settings.settings.liveCaptions = true
        world.catalog.streaming.openFailures.set([.failed("ElevenLabs API Key is invalid")])
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "預算會議", platform: .zoom))
        #expect(await eventually { world.capture.captions.status == .unavailable("ElevenLabs API Key is invalid") })
        await world.capture.stop()
        let meeting = try #require(try await world.library.list().first { $0.metadata.title == "預算會議" })

        #expect(meeting.transcription == expected.transcription)
        #expect(meeting.utterances.map(\.text) == expected.utterances.map(\.text))
        #expect(world.catalog.cloud.calls.get.count == plain.catalog.cloud.calls.get.count)
    }

    @Test func turningCaptionsOnMidMeetingKeepsTheLiveTranscriptionCurrent() async throws {
        var settings = AppSettings()
        let before = settings.forProcessing
        settings.liveCaptions = true
        settings.captionBarOffsets["1"] = CaptionBarOffset(x: 40, y: -12)
        #expect(settings.forProcessing == before)
    }
}
