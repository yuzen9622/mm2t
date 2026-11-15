import Foundation
import MM2TCore

/// A recording's completed clock-time cleanup, available without waiting for new cleanup work.
actor CleanedCheckpointStore {
    struct Reference: Hashable, Sendable {
        let transcript: LLMTranscript
        let cleaned: CleanedTranscript

        func isCompatible(with current: LLMTranscript) -> Bool {
            !transcript.utterances.isEmpty
                && transcript.utterances.count <= current.utterances.count
                && current.utterances.prefix(transcript.utterances.count).elementsEqual(transcript.utterances)
                && transcript.glossary == current.glossary
                && LLMPrompts.isEnglish(transcript.utterances) == LLMPrompts.isEnglish(current.utterances)
        }
    }

    struct Snapshot: Sendable {
        let completed: Reference?

        func reference(for transcript: LLMTranscript) -> Reference? {
            guard let completed, !completed.cleaned.paragraphs.isEmpty,
                  completed.isCompatible(with: transcript) else { return nil }
            return completed
        }
    }

    private var revision: UInt64 = 0
    private var acceptedRevision: UInt64 = 0
    private var latest: Reference?

    func begin() -> UInt64 {
        revision &+= 1
        return revision
    }

    func accept(_ cleaned: CleanedTranscript, for transcript: LLMTranscript, revision: UInt64) {
        guard revision >= acceptedRevision,
              transcript.utterances.count >= (latest?.transcript.utterances.count ?? 0),
              !cleaned.paragraphs.isEmpty else { return }
        let ids = Set(transcript.utterances.map(\.id))
        let speakers = Set(transcript.utterances.map(\.speaker))
        guard cleaned.paragraphs.allSatisfy({ paragraph in
            !paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && speakers.contains(paragraph.speaker)
                && !paragraph.sources.isEmpty
                && Set(paragraph.sources).count == paragraph.sources.count
                && paragraph.sources.allSatisfy(ids.contains)
        }) else { return }
        let times = cleaned.paragraphs.filter {
            $0.text.range(of: #"(?<![0-9:.])(?:[01][0-9]|2[0-3])[：:][0-5][0-9](?![0-9:])"#,
                          options: .regularExpression) != nil
        }
        latest = Reference(transcript: transcript, cleaned: CleanedTranscript(paragraphs: times))
        acceptedRevision = revision
    }

    func reference(for transcript: LLMTranscript) -> Reference? {
        snapshot().reference(for: transcript)
    }

    func snapshot() -> Snapshot { Snapshot(completed: latest) }
}
