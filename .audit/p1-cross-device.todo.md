# P1 cross-device capture and standards fixes

- [x] 1. Reproduce it yourself on the matching surface via the driver skill (Non-negotiables), even when a debug or instrumentation protocol says to ask the user to reproduce. Ask the user only with a stated, specific reason the control surface cannot reach the target, and only after driving it as far as it goes. If it won't reproduce directly, synthesize the trigger, tighten conditions, or instrument until it fires.
- [x] 2. Binary-search the cause. Form the candidate hypotheses, then rule them out until one survives. Seed them with `how` over the affected subsystem and the **why** skill for regression history. Each pass, take the split that cuts the most remaining problem space, get runtime evidence, eliminate. When program state is unclear, add instrumentation or logging and read it as the code runs. Don't guess. Drive a long or stubborn hunt with Claude Code's `loop` skill. Confirm the surviving *mechanism* with runtime evidence before the step-3 architect/interrogate fan-out.
- [x] 3. Plan the fix. If it crosses a function boundary, `architect` first. Delegate implementation to a subagent using your configured bug-fix model (default in poteto-mode's Models section) with a specific scope.
  - Main conversation implements under COMMON.md. Single independent read-only investigation and later independent review. No model substitution or design fan-out.
- [x] 4. Verify on the same surface. The original repro now passes. "Inconclusive" or wrong-surface is not a pass. Flag it. Unit tests show branch behavior, not bug absence.
- [ ] 5. Stage the commits so the failing repro lands before the fix in git history. See the **tdd** skill for the failing-test-first cadence when the bug has a cheap local test path. Skip it when the test would be expensive, integration-heavy, or unclear.
  - skip: no staging or commits requested. Capture failing/passing runtime results locally instead.
- [ ] 6. Run **Opening a PR**.
  - skip: publication not authorized.

## Acceptance

- Actual non-default output audio reaches remote WAV via production AudioRecorder after rebuild; old capture path fails same stimulus.
- Default-route recording and target-process exclusion still work; preserve FineTune relay exclusion.
- Rebuild native app and exercise actual capture. No private microphone content or cloud requests required.
- Privacy describes live processing and correction text uploads. Changelog covers missed user-visible changes.
- Remove unused natural-language deadline resolver and only its dedicated tests; structured deadlines and reminders retain tests.
- Full Swift tests, localization checks, build, independent correctness review, clean diff.

## Design / throughput checkpoint

Data shape remains TapScope (.only process IDs / .allExcept process IDs). Recording follows producer processes, not the system default output. Compare process mixdown against tracking per-process hardware routes: mixdown reuses the existing Core Audio contract; route tracking adds mutable device ownership and listeners. Prefer mixdown if real capture verifies it without duplicate audio. Keep diagnostic device selection only if a current diagnostic needs it.

The reproduction helper discovery runs independently while main updates privacy/changelog and removes dead deadline code. Recording changes wait for failing runtime evidence. Build artifacts stay on KINGSTON. No commits, publication, or user settings changes.

## Verification results (2026-11-14)

Evidence directory: `/private/tmp/claude-501/-Volumes-KINGSTON-yuzen-code-mm2t/c6f8f784-8cef-472f-881a-49eac1228890/scratchpad`.

- Before the fix, `p1-before-built-in.log` records digital silence and exit 1 for a target playing on BuiltInSpeakerDevice. The same old code passed on the default route (`p1-before-default.log`), ruling out a blanket capture-permission failure.
- After the fix, `p1-after-built-in.log`, `p1-after-hdmi.log`, and `p1-after-default.log` each pass. The 440 Hz target measures -25.5 dB, and the simultaneous 1000 Hz decoy stays below -120 dB.
- `p1-app-signed-build.log` records BUILD SUCCEEDED using the existing Apple Development identity. The earlier ad-hoc build compiled but failed to launch due to a llama.framework Team ID mismatch; it is not counted as a successful native run.
- The signed app launched with isolated defaults/data and NoCredentials. LLDB drove its production AudioRecorder with microphone capture disabled. `native-target` and `native-global` contain actual WAVs from sequential built-in/HDMI playback during one recording. Target-mode settled seconds contain 440 Hz at -25.5 dB; both tracks have identical durations and the mic remains silent.
- `native-route-retry-switch` captures one producer process switching built-in → HDMI → built-in during recording. The 440 Hz signal remains present in all three playback intervals. The first route-switch fixture failed because reassigning an active AVAudioPlayer did not restart playback; that run is invalid. The corrected fixture creates a new player on each route within the same process, and its route checks all pass.
- `p1-all-tests.log`: 475 tests reported, including 10 skipped integration/performance tests; 465 passed, no failures. Focused ProcessTap/ActionDeadline/Reminders run: 27 passed.
- `python3 App/Tools/strings.py .build/xcode`: 334 extracted strings checked. `git diff --check`: passed.
- Independent read-only review found no additional concrete defect in the scoped code/docs. It identified an unverified format-change scenario: DeviceIO caches the initial sample rate, and a live aggregate format change without a stalled callback could require rebuilding IO. All available outputs currently use 48 kHz, so switching between different sample rates remains unverified. No device settings were changed to manufacture that condition.
- FineTune exclusion is covered by unit tests, not a live FineTune integration run. No cloud transcription/LLM or real EventKit reminder writes were exercised in this fix.
- Steps 5 and 6 remain skipped, not pending implementation: staging, commits, and publication were not requested.
- Another session owns the localization changes in App/Tools/strings.py, App/Tools/zh-Hant.json, CONTRIBUTING.md, and docs/development.md. Those changes were preserved and are not part of this fix.

