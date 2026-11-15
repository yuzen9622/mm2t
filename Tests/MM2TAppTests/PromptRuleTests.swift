import Foundation
import MM2TCore
import Testing
@testable import MM2TApp

@MainActor @Suite struct PromptRuleTests {
    static let caller = SystemSignals(micBundleIDs: ["com.example.Caller"])
    static let unlisted = DetectedMeeting(platform: nil, client: .desktop, bundleID: "com.example.Caller", isUnlisted: true)

    @Test func alwaysAskSavesTheRuleAndKeepsThePromptWithoutTheLearnChoices() async throws {
        let world = try World()
        await world.capture.handle(Self.caller)
        #expect(world.capture.state == .prompting(Self.unlisted))

        world.capture.alwaysPrompt()
        var listed = Self.unlisted
        listed.isUnlisted = false
        #expect(world.capture.state == .prompting(listed))
        #expect(world.app.settings.settings.detectionRules.app("com.example.Caller")?.prompts == true)

        await world.capture.handle(Self.caller)
        #expect(world.capture.state == .prompting(listed), "the same call goes on; nothing re-prompts")
        await world.capture.startPrompted()
        #expect(world.capture.state.target?.name == "com.example.Caller", "an app the system cannot find is named by its ID")
        #expect(world.capture.state.target?.platform == nil)
    }

    @Test func neverAskSavesTheRuleClosesThePromptAndSilencesTheNextCall() async throws {
        let world = try World()
        await world.capture.handle(Self.caller)
        world.capture.neverAsk()
        #expect(world.capture.state == .idle)
        #expect(world.app.settings.settings.detectionRules.app("com.example.Caller")?.prompts == false)

        await world.capture.handle(SystemSignals(micBundleIDs: []))
        world.now.update { $0 += CaptureController.dismissalCooldown + 1 }
        await world.capture.handle(Self.caller)
        #expect(world.capture.state == .idle)
    }

    @Test func aWebsiteIsLearnedByDomainAndNamedByIt() async throws {
        let world = try World()
        await world.capture.handle(SystemSignals(micBundleIDs: ["com.google.Chrome"], frontmostBundleID: "com.google.Chrome",
                                                 browserURL: URL(string: "https://gather.town/app")))
        guard case .prompting(let meeting) = world.capture.state else { Issue.record("no prompt"); return }
        #expect(world.capture.displayName(of: meeting) == "gather.town")
        world.capture.neverAsk()
        #expect(world.app.settings.settings.detectionRules.sites == [DetectionRule(key: "gather.town", name: "gather.town", prompts: false)])
    }

    static let discord = SystemSignals(micBundleIDs: ["com.hnc.Discord"])
    static let discordAndZoom = SystemSignals(micBundleIDs: ["com.hnc.Discord", "us.zoom.xos"])
    static let discordCall = DetectedMeeting(platform: nil, client: .desktop, bundleID: "com.hnc.Discord")

    @Test func aDeclinedVoiceChannelDoesNotHideAMeetingAndIsNotPromptedWhenItEnds() async throws {
        let world = try World()
        await world.capture.handle(Self.discord)
        world.capture.dismiss()
        await world.capture.handle(Self.discord)
        #expect(world.capture.state == .idle, "declined: not asked again while Discord holds the mic")

        await world.capture.handle(Self.discordAndZoom)
        #expect(world.capture.state == .prompting(.zoomDesktop), "Zoom starting during the voice channel prompts")
        world.capture.dismiss()

        await world.capture.handle(Self.discord)
        #expect(world.capture.state == .idle, "Zoom ending does not bring the declined Discord back")
    }

    @Test func aDeclinedVoiceChannelPromptsAgainInTheNextSession() async throws {
        let world = try World()
        await world.capture.handle(Self.discord)
        world.capture.dismiss()

        await world.capture.handle(Signals.quiet)
        world.now.update { $0 += 10 }
        await world.capture.handle(Self.discord)
        #expect(world.capture.state == .idle, "a rejoin within the cooldown is the same session")

        await world.capture.handle(Signals.quiet)
        world.now.update { $0 += CaptureController.dismissalCooldown + 1 }
        await world.capture.handle(Signals.quiet)
        await world.capture.handle(Self.discord)
        #expect(world.capture.state == .prompting(Self.discordCall))
    }

    @Test func aRecordingIsNotDisturbedByAnotherMeetingStarting() async throws {
        let world = try World()
        await world.capture.handle(Self.discord)
        await world.capture.startPrompted()
        let target = try #require(world.capture.state.target)

        await world.capture.handle(Self.discordAndZoom)
        #expect(world.capture.state == .recording(target))
        #expect(target.bundleID == "com.hnc.Discord" && target.name == "Discord")
        #expect(world.recorder.sessions.get.count == 1)
    }

    /// The card under the user's pointer never swaps to another app: clicking Record must record
    /// what it says. Declining it then reveals the meeting that started meanwhile.
    @Test func anUnansweredPromptStaysAndDecliningItRevealsTheOtherMeeting() async throws {
        let world = try World()
        await world.capture.handle(Self.discord)
        await world.capture.handle(Self.discordAndZoom)
        #expect(world.capture.state == .prompting(Self.discordCall))

        world.capture.dismiss()
        await world.capture.handle(Self.discordAndZoom)
        #expect(world.capture.state == .prompting(.zoomDesktop))
    }

    @Test func recordingAfterDecliningRecordsTheDeclinedCallAndStopsWhenItEnds() async throws {
        let world = try World()
        await world.capture.handle(Self.discord)
        world.capture.dismiss()
        await world.capture.startNow(title: "Recording")
        #expect(world.capture.state.target?.bundleID == "com.hnc.Discord")

        await world.capture.handle(Signals.quiet)
        #expect(world.capture.state == .idle, "the call ending stops the recording")
    }

    @Test func settingsFromABuildWithoutPromptRulesStillLoad() throws {
        let old = #"{"transcriptionOrder":["cloud"],"llmLocation":"cloud","hidesFromScreenCapture":false}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        #expect(settings.detectionRules == DetectionRules())
        #expect(settings.hidesFromScreenCapture == false)

        var changed = settings
        changed.detectionRules.set(DetectionRule(key: "com.hnc.Discord", name: "Discord", prompts: false), in: \.apps)
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed))
        #expect(roundTrip.detectionRules == changed.detectionRules)
    }
}
