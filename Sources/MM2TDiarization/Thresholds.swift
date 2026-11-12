import MM2TCore

extension MatchThresholds {
    /// Defaults for voiceprints from `WeSpeakerEmbedder`. In Evaluation/diarization/RESULTS.md
    /// (門檻建議) no two different speakers scored above 0.611 and same-microphone voiceprints of one
    /// person never below 0.828, so 0.70 auto-names. The evaluation proposed suggesting from 0.50, but different
    /// people in one meeting scored up to 0.607 there, so the user chose 0.70 for both: a
    /// voiceprint match is either confident enough to name or not shown at all. Caveat: 25 AliMeeting speakers, enrolled
    /// and matched within one session, not across real meetings; re-measure on the user's own.
    ///
    /// `user` 0.60: an enrollment of about 10 s against the mean of 1-2.5 s turns from another part of
    /// the meeting. Over 25 AliMeeting speakers in `far` and `nearmix` (220,800 different-speaker
    /// trials), no two different people scored above 0.63 and 0.004% or fewer reached 0.60, while 0.70
    /// missed the speaker in 30-60% of far-field trials. Measured 2026-11-12 on the user's own
    /// recordings: their voice 0.68-0.78 against the enrollment they read aloud, other people 0.25 or less.
    public static let weSpeaker = MatchThresholds(autoName: 0.70, suggest: 0.70, user: 0.60)
}
