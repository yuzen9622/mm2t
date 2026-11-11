import MM2TCore

extension MatchThresholds {
    /// Defaults for voiceprints from `WeSpeakerEmbedder`. In Evaluation/diarization/RESULTS.md
    /// (門檻建議) no two different speakers scored above 0.611 and same-microphone voiceprints of one
    /// person never below 0.828, so 0.70 auto-names; 0.50 sits above the 99th percentile of
    /// different-speaker scores, so it only suggests. Caveat: 25 AliMeeting speakers, enrolled
    /// and matched within one session, not across real meetings; re-measure on the user's own.
    public static let weSpeaker = MatchThresholds(autoName: 0.70, suggest: 0.50)
}
