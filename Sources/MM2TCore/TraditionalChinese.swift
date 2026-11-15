import Foundation

/// Cloud speech services and language models may write Mandarin in Simplified characters; the app's
/// reader is in Taiwan, so everything they return passes through here before it is stored.
enum TraditionalChinese {
    /// Converts the words as one text so context picks the right character (后面 -> 後面, 皇后 stays),
    /// then cuts it back into the same words. The conversion is character for character; if it ever
    /// is not, each word is converted on its own instead.
    static func convert(_ words: [String]) -> [String] {
        let converted = Array(convert(words.joined()))
        guard converted.count == words.reduce(0, { $0 + $1.count }) else { return words.map(convert) }
        var start = 0
        return words.map { word in
            defer { start += word.count }
            return String(converted[start..<start + word.count])
        }
    }

    static func convert(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }
}

extension CleanedTranscript {
    var inTraditionalChinese: CleanedTranscript {
        CleanedTranscript(paragraphs: paragraphs.map {
            .init(speaker: $0.speaker, text: TraditionalChinese.convert($0.text), sources: $0.sources)
        })
    }
}

extension SourcedText {
    var inTraditionalChinese: SourcedText { SourcedText(text: TraditionalChinese.convert(text), sources: sources) }
}

extension PersonDigest {
    var inTraditionalChinese: PersonDigest { PersonDigest(speaker: speaker, points: points.map(\.inTraditionalChinese)) }
}

extension Summary {
    var inTraditionalChinese: Summary {
        Summary(
            headline: headline.map(TraditionalChinese.convert), title: title.map(TraditionalChinese.convert),
            terms: terms?.map(TraditionalChinese.convert),
            decisions: decisions.map(\.inTraditionalChinese), discussionPoints: discussionPoints.map(\.inTraditionalChinese),
            actionItems: actionItems.map { .init(text: TraditionalChinese.convert($0.text), owner: $0.owner, sources: $0.sources, due: $0.due) })
    }
}

extension TranscribedWords {
    var inTraditionalChinese: TranscribedWords {
        let texts = TraditionalChinese.convert(words.map(\.text))
        switch self {
        case .unlabeled(let words):
            return .unlabeled(zip(words, texts).map { TimedWord(text: $1, range: $0.range) })
        case .labeled(let labeled):
            return .labeled(zip(labeled, texts).map { LabeledWord(TimedWord(text: $1, range: $0.word.range), speaker: $0.speaker) })
        }
    }
}

extension TrackTranscript {
    var inTraditionalChinese: TrackTranscript {
        TrackTranscript(source: source, content: content.inTraditionalChinese)
    }
}
