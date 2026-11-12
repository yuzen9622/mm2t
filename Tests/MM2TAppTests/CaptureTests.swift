import Foundation
import MM2TCore
@testable import MM2TSystem
import Testing
@testable import MM2TApp

@MainActor @Suite struct CaptureTests {
    let zoom = DetectedMeeting.zoomDesktop

    @Test func aDetectedMeetingOnlyPromptsAndRecordsOnceTheUserStarts() async throws {
        let world = try World()
        await world.capture.handle(Signals.zoom())
        #expect(world.capture.state == .prompting(zoom))
        #expect(world.recorder.sessions.get.isEmpty, "story 4: nothing records without a click")

        await world.capture.startPrompted()
        let target = try #require(world.capture.state.target)
        #expect(world.capture.state == .recording(target))
        #expect(target.bundleID == "us.zoom.xos" && target.platform == .zoom)
        #expect(world.recorder.last?.configuration.targetBundleID == "us.zoom.xos")
    }

    @Test func aDismissedMeetingDoesNotPromptAgainUntilItHasReallyEnded() async throws {
        let world = try World()
        await world.capture.handle(Signals.zoom())
        world.capture.dismiss()
        #expect(world.capture.state == .idle)

        await world.capture.handle(Signals.zoom())
        #expect(world.capture.state == .idle, "same meeting still running")

        await world.capture.handle(Signals.quiet)
        world.now.update { $0 += 30 }
        await world.capture.handle(Signals.zoom())
        #expect(world.capture.state == .idle, "a rejoin within the cooldown is the same meeting")

        await world.capture.handle(Signals.quiet)
        world.now.update { $0 += CaptureController.dismissalCooldown + 1 }
        await world.capture.handle(Signals.zoom())
        #expect(world.capture.state == .prompting(zoom), "a later meeting in the same app prompts again")
        #expect(world.recorder.sessions.get.isEmpty)
    }

    @Test func dismissingOneMeetingStillPromptsForAnotherApp() async throws {
        let world = try World()
        await world.capture.handle(Signals.zoom())
        world.capture.dismiss()
        await world.capture.handle(Signals.quiet)
        await world.capture.handle(Signals.teams)
        #expect(world.capture.state == .prompting(DetectedMeeting.teamsDesktop))
    }

    @Test func aPromptDisappearsWhenTheMeetingEndsBeforeTheUserAnswers() async throws {
        let world = try World()
        await world.capture.handle(Signals.zoom())
        await world.capture.handle(Signals.quiet)
        #expect(world.capture.state == .idle)
    }

    @Test func theMeetingEndingStopsTheRecordingAndProcessesIt() async throws {
        let world = try World()
        await world.capture.handle(Signals.zoom())
        await world.capture.startPrompted()
        await world.capture.handle(Signals.quiet)

        #expect(world.capture.state == .idle)
        let meeting = try #require(try await world.library.list().first)
        #expect(world.queue.jobs[meeting.id] == .completed, "story 23: processing starts without a click")
        let processed = try await world.library.meeting(meeting.id)
        #expect(processed.status == .completed)
        #expect(processed.utterances.contains { $0.speaker == .me && $0.text.contains("決定") })
        #expect(Set(processed.speakers.map(\.label)) == ["A", "B"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: world.app.paths.recordings.path)
        #expect(leftovers.isEmpty, "the session folder is cleared once the library owns the tracks")
    }

    @Test func aPausedRecordingAlsoStopsWhenTheMeetingEnds() async throws {
        let world = try World()
        await world.capture.handle(Signals.zoom())
        await world.capture.startPrompted()
        await world.capture.pause()
        #expect(world.capture.state.isCapturing)
        if case .paused = world.capture.state {} else { Issue.record("expected paused, got \(world.capture.state)") }
        #expect(await world.recorder.last?.isPaused == true)

        await world.capture.handle(Signals.quiet)
        #expect(world.capture.state == .idle)
        #expect(try await world.library.list().count == 1)
    }

    @Test func theMeetingEndingCountsDownAndTheUserCanKeepRecording() async throws {
        let world = try World(endCountdown: .seconds(30))
        await world.capture.handle(Signals.zoom())
        await world.capture.startPrompted()
        await world.capture.pause()
        await world.capture.handle(Signals.quiet)

        guard case .endingSoon(let target, let deadline) = world.capture.state else {
            Issue.record("expected a countdown, got \(world.capture.state)")
            return
        }
        #expect(world.capture.state.isCapturing && target.bundleID == "us.zoom.xos")
        #expect(deadline == world.now.get.addingTimeInterval(30))
        #expect(try await world.library.list().isEmpty, "nothing is saved while the user can still keep going")

        await world.capture.keepRecording()
        #expect(world.capture.state == .paused(target), "keeping it returns to where it was")
        await world.capture.stop()
        let saved = try await world.library.list().count
        #expect(world.capture.state == .idle && saved == 1)
    }

    @Test func theCountdownStopsTheRecordingWhenNobodyAnswers() async throws {
        let world = try World(endCountdown: .milliseconds(50))
        await world.capture.handle(Signals.zoom())
        await world.capture.startPrompted()
        await world.capture.handle(Signals.quiet)
        if case .endingSoon = world.capture.state {} else { Issue.record("expected a countdown, got \(world.capture.state)") }

        for _ in 0..<200 where !(try await world.library.list().count == 1) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await world.library.list().count == 1)
    }

    @Test func aWholeMacRecordingCountsDownWhenTheMeetingItWasStartedForEnds() async throws {
        let world = try World(endCountdown: .seconds(30))
        await world.capture.startNow(title: "錄音")
        await world.capture.handle(Signals.zoom())
        await world.capture.handle(Signals.quiet)
        if case .endingSoon(let target, _) = world.capture.state {
            #expect(target.bundleID == nil)
        } else {
            Issue.record("expected a countdown, got \(world.capture.state)")
        }
    }

    @Test func anotherAppReleasingTheMicDoesNotStopAManualRecording() async throws {
        let world = try World()
        await world.capture.startManually(RecordingTarget(bundleID: "com.google.Chrome", name: "Chrome", platform: nil))
        await world.capture.handle(Signals.zoom())
        await world.capture.handle(Signals.quiet)
        #expect(world.capture.state.target?.bundleID == "com.google.Chrome")
        #expect(world.capture.state.isCapturing)
        #expect(world.capture.state.target?.isBrowser == true, "story 11: the UI warns about other tabs")
    }

    @Test func theRecordButtonPicksTheMeetingInProgressWithoutAsking() async throws {
        let world = try World()
        await world.capture.handle(Signals.zoom())
        world.capture.dismiss()

        await world.capture.startNow(title: "錄音")
        #expect(world.recorder.last?.configuration.targetBundleID == "us.zoom.xos")
        #expect(world.capture.state.target?.platform == .zoom)
    }

    @Test func theRecordButtonRecordsTheWholeMacWhenNoMeetingIsDetected() async throws {
        let world = try World()
        await world.capture.startNow(title: "錄音")

        let target = try #require(world.capture.state.target)
        #expect(world.capture.state == .recording(target))
        #expect(target.bundleID == nil && !target.isBrowser)
        let configuration = try #require(world.recorder.last?.configuration)
        #expect(configuration.targetBundleID == nil && configuration.title == "錄音")
    }

    @Test func manualStartRecordsTheChosenApp() async throws {
        let world = try World()
        let target = RecordingTarget(bundleID: "com.apple.Safari", name: "週會", platform: nil)
        await world.capture.startManually(target)
        #expect(world.capture.state == .recording(target))
        #expect(world.recorder.last?.configuration.targetBundleID == "com.apple.Safari")
        #expect(world.recorder.last?.configuration.title == "週會")
    }

    @Test func recordingWaitsForTheMicrophoneAnswerBeforeStarting() async throws {
        let world = try World()
        world.permissions.mic.set(.notDetermined)
        await world.capture.handle(Signals.zoom())
        let start = Task { await world.capture.startPrompted() }

        #expect(await eventually { if case .awaitingMicrophone = world.capture.state { true } else { false } })
        #expect(world.recorder.sessions.get.isEmpty, "no recorder start while the prompt is open")

        await world.permissions.answer.open(true)
        await start.value
        #expect(world.capture.state.isCapturing)
        #expect(world.recorder.sessions.get.count == 1)
    }

    @Test func refusingTheMicrophoneFailsWithALinkToItsSettingsPane() async throws {
        let world = try World()
        world.permissions.mic.set(.notDetermined)
        await world.permissions.answer.open(false)
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "Zoom", platform: .zoom))
        #expect(world.capture.state == .failed(.microphoneDenied))
        #expect(CaptureFailure.microphoneDenied.settingsPane == .microphone)
        #expect(world.recorder.sessions.get.isEmpty)

        world.capture.acknowledgeFailure()
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "Zoom", platform: .zoom))
        #expect(world.capture.state == .failed(.microphoneDenied), "already denied: fail at once, no second prompt")
        #expect(world.permissions.micRequests.get == 1)
    }

    @Test func aRecorderErrorBecomesAFailureTheUserCanFixInSettings() async throws {
        let world = try World()
        let error = RecorderError.systemAudioCaptureUnavailable(CoreAudioError(operation: "tap", status: -1))
        world.recorder.failure.set(error)
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "Zoom", platform: .zoom))
        guard case .failed(let failure) = world.capture.state else { Issue.record("not failed"); return }
        #expect(failure == .recorder(error))
        #expect(failure.settingsPane == .systemAudio)
    }

    @Test func highlightsAndSilentRemoteWarningsReachTheMeters() async throws {
        let world = try World()
        await world.capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: "Zoom", platform: .zoom))
        let session = try #require(world.recorder.last)
        await session.advance(12)
        await world.capture.markHighlight()
        #expect(world.capture.meters.highlightCount == 1)

        session.send(.remoteSilentWhileTargetPlaying)
        #expect(await eventually { world.capture.meters.remoteSilentWhilePlaying })

        await world.capture.stop()
        let meeting = try #require(try await world.library.list().first)
        #expect(meeting.highlights == [Highlight(time: 12)], "story 20: the star reaches the meeting")
    }

    @Test func aNewMeetingCanBeRecordedWhileTheLastOneIsProcessing() async throws {
        let world = try World()
        let gate = Gate<Bool>()
        world.catalog.llm.holds.update { $0["summarize"] = gate }
        await world.capture.handle(Signals.zoom())
        await world.capture.startPrompted()
        let ending = Task { await world.capture.handle(Signals.quiet) }
        #expect(await eventually { world.queue.activeJob != nil && world.capture.state == .idle })

        await world.capture.handle(Signals.teams)
        #expect(world.capture.state == .prompting(DetectedMeeting.teamsDesktop))
        await gate.open(true)
        await ending.value
    }
}

extension DetectedMeeting {
    static var zoomDesktop: DetectedMeeting {
        MeetingDetector.evaluate(Signals.zoom(), current: nil).current!
    }
    static var teamsDesktop: DetectedMeeting {
        MeetingDetector.evaluate(Signals.teams, current: nil).current!
    }
}
