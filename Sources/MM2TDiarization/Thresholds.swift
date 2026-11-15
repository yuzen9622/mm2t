import MM2TCore

extension MatchThresholds {
    /// Scores from 0.60 to below 0.70 require confirmation: different speakers reached 0.607
    /// in Evaluation/diarization/RESULTS.md, so this range must not automatically assign a person.
    ///
    /// `user` 0.60: an enrollment of about 10 s against the mean of 1-2.5 s turns from another part of
    /// the meeting. Over 25 AliMeeting speakers in `far` and `nearmix` (220,800 different-speaker
    /// trials), no two different people scored above 0.63 and 0.004% or fewer reached 0.60, while 0.70
    /// missed the speaker in 30-60% of far-field trials. Measured 2026-11-12 on the user's own
    /// recordings: their voice 0.68-0.78 against the enrollment they read aloud, other people 0.25 or less.
    public static let weSpeaker = MatchThresholds(autoName: 0.70, suggest: 0.60, user: 0.60)
}
