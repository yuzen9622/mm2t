import Foundation

extension Meeting {
    /// Some cleaners return one paragraph per ASR fragment, even mid-turn.
    mutating func joinCleanedFragments() {
        guard let cleaned = outputs.cleaned, cleaned.paragraphs.count > 1 else { return }
        let paragraphs = cleaned.paragraphs
        let translation = currentTranslation
        let positions = Dictionary(utterances.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })

        func fragmentPosition(_ paragraph: CleanedTranscript.Paragraph) -> Int? {
            guard paragraph.sources.count == 1, let source = paragraph.sources.first,
                  let index = positions[source], utterances[index].speaker == paragraph.speaker,
                  !paragraph.text.isEmpty, paragraph.text.count <= 45,
                  !paragraph.text.contains(where: \.isNewline),
                  paragraph.text.firstMatch(of: /^\s*(?:[-*•#>]|\d+[.)])\s/) == nil else { return nil }
            return index
        }

        var groups: [Range<Int>] = []
        var start = 0
        var length = 0
        var previous: Int?
        for (index, paragraph) in paragraphs.enumerated() {
            let position = fragmentPosition(paragraph)
            // Keep a reading paragraph within about two lines, with at most a short pause.
            if let position, let previous, position == previous + 1,
               paragraph.speaker == paragraphs[index - 1].speaker,
               utterances[position].range.start - utterances[previous].range.end <= 3,
               length + paragraph.text.count + 1 <= 90,
               (translation?.paragraphs[index] == nil) == (translation?.paragraphs[index - 1] == nil) {
                length += paragraph.text.count + 1
            } else {
                if index > start { groups.append(start..<index) }
                start = index
                length = paragraph.text.count
            }
            previous = position
        }
        groups.append(start..<paragraphs.count)
        guard groups.count < paragraphs.count else { return }

        func joined(_ texts: [String]) -> String {
            texts.reduce(into: "") { text, next in
                if let last = text.last, let first = next.first,
                   !last.isWhitespace, !first.isWhitespace,
                   (last.isLetter || last.isNumber || ".!?,;:…)”’".contains(last)),
                   (first.isLetter || first.isNumber || "(“‘".contains(first)),
                   !PartialTranslationPolicy.isHan(last), !PartialTranslationPolicy.isHan(first) { text += " " }
                text += next
            }
        }
        let result = CleanedTranscript(paragraphs: groups.map { group in
            let parts = paragraphs[group]
            return .init(speaker: paragraphs[group.lowerBound].speaker,
                         text: joined(parts.map(\.text)), sources: parts.flatMap(\.sources))
        })
        outputs.cleaned = result
        if let translation {
            var headings: [Int: String] = [:]
            for (index, group) in groups.enumerated() where translation.paragraphs[group.lowerBound] != nil {
                headings[index] = joined(group.compactMap { translation.paragraphs[$0] })
            }
            self.translation = .init(target: translation.target, source: result, paragraphs: headings)
        }
    }
}
