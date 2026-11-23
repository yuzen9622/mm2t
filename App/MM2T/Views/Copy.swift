import Foundation
import MM2TApp
import MM2TCore
import MM2TProviders
import MM2TSystem

/// Every user-facing string derived from a logic value goes through here, so the String Catalog
/// holds all of them and `MM2TApp` stays free of UI text.
enum Copy {
    static let presentationLabels = PresentationLabels(
        me: String(localized: "Me"),
        viewTitle: { view(for: $0) },
        overlapping: String(localized: "overlapping speech"),
        notGenerated: String(localized: "Not generated yet."),
        stale: String(localized: "Speakers changed since this was generated. Regenerate to update it."),
        decisions: String(localized: "Decisions"),
        discussionPoints: String(localized: "Discussion points"),
        actionItems: String(localized: "Action items"),
        owner: { String(localized: "owner: \($0)") },
        microphone: String(localized: "Microphone"), remoteAudio: String(localized: "Remote audio"))

    static func view(for view: TranscriptView) -> String {
        switch view {
        case .raw: String(localized: "Transcript")
        case .cleaned: String(localized: "Cleaned transcript")
        case .perPerson: String(localized: "By person")
        case .summary: String(localized: "Summary")
        }
    }

    /// The prompt's title: a meeting for the four platforms; any other app or site is only known
    /// to be using the mic, which may not be a call.
    static func detectedCall(_ meeting: DetectedMeeting, name: String) -> String {
        meeting.platform != nil ? String(localized: "\(name) meeting") : String(localized: "\(name) is using the mic")
    }

    static func step(_ step: ProcessingStep?) -> String {
        switch step {
        case nil: String(localized: "Preparing")
        case .transcribe: String(localized: "Transcribing")
        case .diarize: String(localized: "Separating speakers")
        case .matchVoiceprints: String(localized: "Recognizing speakers")
        case .align: String(localized: "Aligning words to speakers")
        case .inferNames: String(localized: "Guessing names")
        case .cleanTranscript: String(localized: "Cleaning up the transcript")
        case .digestPerPerson: String(localized: "Summarizing each person")
        case .summarize: String(localized: "Writing the summary")
        }
    }

    static func status(_ status: MeetingRow.Status) -> String {
        switch status {
        case .notProcessed: String(localized: "Not processed")
        case .processing(let step): step.map(Self.step) ?? String(localized: "Waiting to process")
        case .needsSetup: String(localized: "Waiting for setup")
        case .failed: String(localized: "Processing failed")
        case .completed: String(localized: "Done")
        }
    }

    static func job(_ state: JobState) -> String {
        switch state {
        case .queued: String(localized: "Waiting to process")
        case .running(let step): Self.step(step)
        case .needsSetup: String(localized: "Waiting for setup")
        case .failed(_, let reason): String(localized: "Processing failed: \(reason)")
        case .completed: String(localized: "Done")
        }
    }

    static func issue(_ issue: SetupIssue) -> String {
        switch issue {
        case .transcriptionServiceNotConfigured(.mm2t), .summaryServiceNotConfigured(.mm2t):
            String(localized: "Sign in to use your mm2t plan.")
        case .transcriptionServiceNotConfigured(.elevenLabs): String(localized: "Add your ElevenLabs API key.")
        case .summaryServiceNotConfigured(.gemini): String(localized: "Add your Gemini API key.")
        case .transcriptionServiceNotConfigured(.server): String(localized: "Set up your transcription server.")
        case .summaryServiceNotConfigured(.openAICompatible): String(localized: "Set the OpenAI-compatible server URL and model name.")
        case .diarizationModelsMissing: String(localized: "Download the speaker separation model.")
        }
    }

    static func calendarSource(_ kind: CalendarSourceKind) -> String {
        switch kind {
        case .apple: String(localized: "Apple Calendar")
        case .google: String(localized: "Google Calendar")
        case .microsoft: String(localized: "Outlook")
        }
    }

    static func calendarSourceDetail(_ kind: CalendarSourceKind) -> String {
        switch kind {
        case .apple: String(localized: "iCloud and the accounts this Mac already syncs")
        case .google: String(localized: "Your primary Google calendar")
        case .microsoft: String(localized: "Microsoft 365 or Outlook.com")
        }
    }

    /// The one line a source shows instead of its Connect button when this build cannot connect it.
    static func calendarUnavailable(_ kind: CalendarSourceKind) -> String {
        switch kind {
        case .apple: String(localized: "macOS isn't letting mm2t read calendars.")
        case .google: String(localized: "Not available in this build: it has no Google OAuth client ID.")
        case .microsoft: String(localized: "Not available in this build: it has no Microsoft OAuth client ID.")
        }
    }

    static func calendarProblem(_ problem: CalendarProblem, _ kind: CalendarSourceKind) -> String {
        switch problem {
        case .signInFailed: String(localized: "Sign-in didn't finish. Try again.")
        case .googleOAuth(let failure):
            if failure.reason == .clientSecretRequired {
                String(localized: "Google sign-in needs an iOS-type OAuth client ID in this build (client_secret_required).")
            } else {
                String(localized: "Google sign-in failed (\(failure.diagnostic)).")
            }
        case .unreachable: String(localized: "Couldn't reach \(calendarSource(kind)).")
        case .signedOut: String(localized: "\(calendarSource(kind)) signed you out. Connect it again.")
        }
    }

    static func permissionState(_ state: PermissionState) -> String {
        switch state {
        case .granted: String(localized: "Allowed")
        case .denied: String(localized: "Not allowed")
        case .notDetermined: String(localized: "Not asked yet")
        case .unknown: String(localized: "Checked when you record")
        }
    }

    static func failure(_ failure: CaptureFailure) -> String {
        switch failure {
        case .microphoneDenied:
            String(localized: "mm2t can't use the microphone. Allow it in System Settings, then try again.")
        case .recorder(.systemAudioCaptureUnavailable):
            String(localized: "mm2t can't record the meeting app's audio. Allow system audio recording in System Settings.")
        case .recorder(.noInputDevice):
            String(localized: "No microphone is connected.")
        case .recorder(let error):
            String(localized: "Recording could not start: \(String(describing: error))")
        case .saveFailed(let reason):
            String(localized: "The recording is safe but could not be added to your meetings: \(reason). mm2t will try again at next launch.")
        }
    }

    static func enrollment(_ problem: VoiceEnrollmentModel.Problem) -> String {
        switch problem {
        case .tooShort: String(localized: "That was too short to learn your voice. Read the whole passage, a little closer to the microphone.")
        case .differentWords: String(localized: "That didn't sound like the passage. Read it once more; it doesn't have to be word for word.")
        case .modelMissing: String(localized: "Download the speaker separation model first.")
        case .microphoneDenied: String(localized: "mm2t can't use the microphone. Allow it in System Settings, then try again.")
        case .failed(let reason): reason
        }
    }

    static func keyState(_ state: KeyState) -> String {
        switch state {
        case .empty: ""
        case .saved: String(localized: "Saved in Keychain")
        case .validating: String(localized: "Checking…")
        case .checked(.valid): String(localized: "Key works")
        case .checked(.rejected(let message)), .checked(.inconclusive(let message)): message
        case .needsServerURL: String(localized: "Enter the server URL first.")
        case .storageFailed(let reason): reason
        }
    }
}
