import MM2TApp
import MM2TCore
import SwiftUI

/// Rename, accept a suggestion, merge (stories 37-43). Disabled while the pipeline owns the meeting.
struct SpeakerPanel: View {
    let model: MeetingDetailModel
    @State private var renaming: SpeakerRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.speakers) { speaker in
                SpeakerRowView(speaker: speaker, others: model.speakers.filter { $0.id != speaker.id },
                               canClaim: model.canClaimAsMe(speaker.id),
                               rename: { renaming = speaker },
                               claim: { Task { await model.claimAsMe(speaker.id) } },
                               merge: { other in Task { await model.merge(speaker.id, into: other) } },
                               accept: { Task { await model.acceptSuggestion(for: speaker.id) } })
            }
            if model.isProcessing {
                Text("Speakers can be edited when processing finishes.").font(Typo.caption).foregroundStyle(Palette.secondary)
                    .padding(.top, 6)
            }
        }
        .card()
        .disabled(!model.canEditSpeakers)
        .opacity(model.canEditSpeakers ? 1 : 0.6)
        .motion(Motion.reveal, value: model.speakers.map(\.displayName))
        .sheet(item: $renaming) { speaker in
            RenameSheet(speaker: speaker, people: model.people) { target in
                Task { await model.rename(speaker.id, to: target) }
            }
        }
    }
}

struct SpeakerRowView: View {
    let speaker: SpeakerRow
    let others: [SpeakerRow]
    var canClaim = false
    let rename: () -> Void
    var claim: () -> Void = {}
    let merge: (SpeakerID) -> Void
    let accept: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Avatar(name: speaker.displayName, isNamed: speaker.person != nil)
                Text(speaker.displayName).font(Typo.bodyStrong).lineLimit(1)
                Spacer(minLength: 4)
                Menu {
                    Button("Rename…", action: rename)
                    if canClaim {
                        Button("This Is Me", action: claim)
                    }
                    Menu("Merge Into") {
                        ForEach(others) { other in Button(other.displayName) { merge(other.id) } }
                    }
                } label: {
                    Icon("dots", size: 16).foregroundStyle(Palette.secondary).frame(width: 26, height: 26).contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hovering ? 1 : 0)
            }
            if let suggestion = speaker.suggestion {
                Button(action: accept) {
                    HStack(spacing: 5) {
                        Text(verbatim: "\(suggestion.name)？").font(Typo.captionStrong)
                        Icon("check", size: 12)
                    }
                    .foregroundStyle(Palette.orange)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Palette.orangeSoft, in: Capsule())
                }
                .buttonStyle(Pressable())
                .help(reason(suggestion))
                .padding(.leading, 35)
                .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
    }

    private func reason(_ suggestion: SpeakerRow.Suggestion) -> String {
        switch suggestion {
        case .voiceprint(_, let similarity):
            String(localized: "Voice similarity \(similarity, format: .percent.precision(.fractionLength(0)))")
        case .inferred(_, let reason):
            reason
        }
    }
}

struct RenameSheet: View {
    let speaker: SpeakerRow
    let people: [Person]
    let commit: (SpeakerEditing.Target) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename \(speaker.displayName)").font(Typo.heading)
            HStack(spacing: 8) {
                FieldBox { TextField("Name", text: $name).onSubmit(save) }
                PillButton("Save", kind: .primary, action: save)
                    .disabled(trimmed.isEmpty)
            }
            if !people.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(people) { person in
                            PersonPick(name: person.name) {
                                commit(.existing(person.id))
                                dismiss()
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            HStack {
                Spacer()
                PillButton("Cancel") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(Palette.window)
        .foregroundStyle(Palette.text)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private func save() {
        guard !trimmed.isEmpty else { return }
        commit(.newPerson(name: trimmed))
        dismiss()
    }
}

struct PersonPick: View {
    let name: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Avatar(name: name, isNamed: true)
                Text(name)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(hovering ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
    }
}
