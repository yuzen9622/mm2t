import MM2TApp
import SwiftUI

/// The user's terms, by who added them: typed here, or learned by mm2t from a meeting or a correction.
struct VocabularyView: View {
    enum Filter: Hashable, CaseIterable { case all, learned, manual }

    let store: SettingsStore
    @State private var filter = Filter.all
    @State private var draft = ""

    private var terms: [String] {
        let settings = store.settings
        return settings.vocabulary.reversed().filter { term in
            switch filter {
            case .all: true
            case .learned: settings.source(of: term) == .learned
            case .manual: settings.source(of: term) == .manual
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                Segmented(options: Filter.allCases, selection: $filter) { title($0) }
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    FieldBox {
                        TextField("Add a name, product or term", text: $draft).onSubmit(add)
                    }
                    PillButton("Add", icon: "plus", kind: .primary, action: add)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("mm2t listens for these words and spells them your way. It also adds terms it hears in your meetings and the ones you correct in a transcript.")
                    .font(Typo.caption).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                if terms.isEmpty {
                    EmptyState(icon: "book-2", title: filter == .learned ? "Nothing learned yet" : "No terms yet")
                } else {
                    ScrollView {
                        FlowLayout(spacing: 8) {
                            ForEach(terms, id: \.self) { term in
                                TermChip(term: term, isLearned: store.settings.source(of: term) == .learned) {
                                    store.settings.removeVocabulary(term)
                                }
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 24)
                        .motion(Motion.reveal, value: terms)
                    }
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func add() {
        store.settings.addVocabulary(draft, source: .manual)
        draft = ""
    }

    private func title(_ filter: Filter) -> String {
        let settings = store.settings
        switch filter {
        case .all: return String(localized: "All \(settings.vocabulary.count)")
        case .learned: return String(localized: "Auto-added \(settings.learnedVocabulary.count)")
        case .manual: return String(localized: "Manually added \(settings.vocabulary.count - settings.learnedVocabulary.count)")
        }
    }
}

private struct TermChip: View {
    let term: String
    let isLearned: Bool
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if isLearned { Icon("sparkles", size: 13).foregroundStyle(Palette.orange) }
            Text(verbatim: term).font(Typo.bodyStrong).lineLimit(1)
            Button(action: remove) {
                Icon("x", size: 12).foregroundStyle(hovering ? Palette.danger : Palette.muted)
                    .frame(width: 16, height: 16).contentShape(Circle())
            }
            .buttonStyle(Pressable())
            .accessibilityLabel("Delete")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 32)
        .background(Palette.card, in: Capsule())
        .overlay(Capsule().strokeBorder(hovering ? Palette.orange.opacity(0.45) : Palette.border))
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
        .accessibilityElement(children: .combine)
    }
}
