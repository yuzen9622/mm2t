import Foundation

/// A transient model result used to verify which term changed; only the corrected term is saved.
public struct VocabularyCorrection: Hashable, Sendable {
    public let incorrect: String
    public let correct: String

    public init(incorrect: String, correct: String) {
        self.incorrect = incorrect
        self.correct = correct
    }
}

/// Grounds the model's noun corrections in the exact edit. Semantic classification belongs to
/// the model; this boundary rejects invented spellings, insertions, punctuation and sentence edits.
public enum VocabularyLearning {
    public static func validated(_ corrections: [VocabularyCorrection], from old: String, to new: String) -> [VocabularyCorrection] {
        guard normalized(old) != normalized(new) else { return [] }
        var seen = Set<VocabularyCorrection>()
        let candidates = corrections.filter { pair in
            validTerm(pair.incorrect) && validTerm(pair.correct)
                && normalized(pair.incorrect) != normalized(pair.correct)
                && !addsWords(around: pair.incorrect, in: pair.correct)
                && !addsWords(around: pair.correct, in: pair.incorrect)
                && old.contains(pair.incorrect) && new.contains(pair.correct)
                && seen.insert(pair).inserted
        }
        let before = normalized(old), after = normalized(new)
        let distance = editCost(from: before, to: after)
        return candidates.filter { pair in
            let incorrect = normalized(pair.incorrect), correct = normalized(pair.correct)
            let correctionCost = editCost(from: incorrect, to: correct)
            return before.ranges(of: incorrect).contains { range in
                var replaced = before
                replaced.replaceSubrange(range, with: correct)
                // Applying this replacement must account for that part of the actual edit.
                // Merely finding the two spellings elsewhere in the passage is insufficient.
                return distance - editCost(from: replaced, to: after) == correctionCost
            }
        }
    }

    private static func editCost(from old: String, to new: String) -> Int {
        Array(new).difference(from: Array(old)).count
    }

    private static func validTerm(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text == trimmed && !text.isEmpty && text.count <= 80
            && (text.count > 1 || text.first?.isASCII == true)
            && text.contains(where: \.isLetter)
            && !text.contains(where: { $0.isNewline || "。！？!?，,；;：:".contains($0) })
            && text.split(whereSeparator: \.isWhitespace).count <= 6
    }

    private static func addsWords(around term: String, in text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.count > 1 && words.contains(Substring(term))
    }

    private static func normalized(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }
}
