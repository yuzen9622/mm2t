import MM2TApp
import MM2TCore
import SwiftUI

struct VoiceprintsView: View {
    let model: VoiceprintsModel
    @State private var editing: PersonRow?
    @State private var newName = ""
    @State private var deleting: PersonRow?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {}
            if model.rows.isEmpty {
                EmptyState(icon: "users", title: "Naming a speaker in a meeting saves their voiceprint on this Mac.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.rows) { person in
                            HStack(spacing: 12) {
                                Avatar(name: person.name, isNamed: true, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.name).font(Typo.bodyStrong)
                                    VoiceprintSummary(count: person.voiceprintCount, channels: person.channels)
                                }
                                Spacer()
                                IconButton("Rename…", icon: "pencil") {
                                    newName = person.name
                                    editing = person
                                }
                                IconButton("Delete…", icon: "trash") { deleting = person }
                            }
                            .card()
                            .transition(.asymmetric(insertion: .offset(y: 10).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .motion(Motion.page, value: model.rows.map(\.id))
                }
            }
        }
        .task { await model.reload() }
        .alert("Rename", isPresented: .init(get: { editing != nil }, set: { if !$0 { editing = nil } }), presenting: editing) { person in
            TextField("Name", text: $newName)
            Button("Save") { Task { await model.rename(person.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this person?", isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { person in
            Button("Delete \(person.name) and Their Voiceprints", role: .destructive) { Task { await model.delete(person.id) } }
        } message: { _ in
            Text("Their voiceprints are removed from this Mac. Past meetings show the speaker's letter again.")
        }
    }
}

/// How many vectors a person has and where they were heard. A voice known only from the room
/// scores low on a call until it is named there once, so that gap is spelled out.
struct VoiceprintSummary: View {
    let count: Int
    let channels: Set<VoiceChannel>

    var body: some View {
        if count == 0 {
            Text("No voiceprint yet").font(Typo.caption).foregroundStyle(Palette.muted)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("^[\(count) voiceprint](inflect: true)").font(Typo.caption).foregroundStyle(Palette.secondary)
                    if channels.contains(.room) { ChannelTag(title: "In the room") }
                    if channels.contains(.call) { ChannelTag(title: "On calls") }
                }
                if !channels.contains(.call) {
                    Text("No call voiceprint yet. Name them once during a call and they will be recognized.")
                        .font(Typo.caption).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ChannelTag: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(Typo.captionStrong)
            .foregroundStyle(Palette.orange)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Palette.orangeSoft, in: Capsule())
    }
}
