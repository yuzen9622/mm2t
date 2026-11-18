import MM2TCore

extension MatchThresholds {
    /// Measured on AliMeeting with Nemotron-3 clusters, a voiceprint from a cluster's first half against
    /// 8 s or more of its second half (Evaluation/diarization/RESULTS.md, "CAM++ 門檻"). No two
    /// different speakers scored above 0.623, so from 0.70 a person is named; the same speaker never
    /// fell below 0.706, so 0.60-0.70 only suggests a name for the user to confirm.
    ///
    /// `user` 0.62: about 10 s of enrollment against means of 1-2.5 s turns. Different people reached
    /// 0.62 in 0.0023% of trials or fewer, against 0.0058% at 0.60, while the user was missed in 2.0%
    /// of far-field trials averaging three turns.
    public static let campPlus = MatchThresholds(autoName: 0.70, suggest: 0.60, user: 0.62)
}
