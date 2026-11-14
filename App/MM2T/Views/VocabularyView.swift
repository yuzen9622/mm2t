import MM2TApp
import SwiftUI

/// Terms entered by the user or learned from their saved transcript corrections.
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
                Text("When you save a transcript correction, mm2t automatically adds the names and terms you corrected to your vocabulary.")
                    .font(Typo.caption).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                if terms.isEmpty {
                    EmptyState(icon: "book-2", title: filter == .learned ? "Nothing learned yet" : "No terms yet")
                } else {
                    FadingScrollView {
                        FlowLayout(spacing: 8) {
                            ForEach(terms, id: \.self) { term in
                                TermChip(term: term, isLearned: store.settings.source(of: term) == .learned,
                                         canRename: { canRename(term, to: $0) }, rename: { rename(term, to: $0) }) {
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

    /// The edited spelling, trimmed; nil when there is nothing to save.
    private static func cleaned(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Refuses a spelling that another term already has, or that would split into several terms
    /// the way the Add field splits them. Empty or unchanged text is a no-op, not a refusal.
    private func canRename(_ term: String, to text: String) -> Bool {
        guard let new = Self.cleaned(text), new != term else { return true }
        if new.contains(where: { $0.isNewline || $0 == "," || $0 == "，" }) { return false }
        var trial = store.settings
        return trial.renameVocabulary(term, to: new)
    }

    /// Replaces the term's spelling in place; the edited term becomes the user's own.
    private func rename(_ term: String, to text: String) {
        guard let new = Self.cleaned(text), new != term, canRename(term, to: new) else { return }
        store.settings.renameVocabulary(term, to: new)
    }

    private func title(_ filter: Filter) -> String {
        let settings = store.settings
        switch filter {
        case .all: return String(localized: "All \(settings.vocabulary.count)")
        case .learned: return String(localized: "Learned from corrections \(settings.learnedVocabulary.count)")
        case .manual: return String(localized: "Manually added \(settings.vocabulary.count - settings.learnedVocabulary.count)")
        }
    }
}

private struct TermChip: View {
    let term: String
    let isLearned: Bool
    let canRename: (String) -> Bool
    let rename: (String) -> Void
    let remove: () -> Void
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var refused: Bool { editing && !canRename(draft) }
    private var splits: Bool { draft.contains { $0.isNewline || $0 == "," || $0 == "，" } }

    var body: some View {
        HStack(spacing: 6) {
            if isLearned { Icon("sparkles", size: 13).foregroundStyle(Palette.orange) }
            if editing {
                // The hidden copy sizes the field to what is typed, in any script.
                Text(verbatim: draft.isEmpty ? term : draft).font(Typo.bodyStrong).lineLimit(1).hidden()
                    .padding(.trailing, 4)
                    .frame(minWidth: 40)
                    .overlay {
                        TextField(text: $draft, prompt: Text(verbatim: term)) { Text(verbatim: term) }
                            .textFieldStyle(.plain)
                            .font(Typo.bodyStrong)
                            .focused($focused)
                            .onSubmit(save)
                            .onExitCommand(perform: cancel)
                            .onChange(of: focused) { _, now in if !now { leave() } }
                    }
                if refused {
                    Text(splits ? "One term at a time" : "Already in your vocabulary")
                        .font(Typo.caption).foregroundStyle(Palette.danger).lineLimit(1)
                }
            } else {
                Text(verbatim: term).font(Typo.bodyStrong).lineLimit(1)
                    .onTapGesture(count: 2, perform: edit)
                if hovering {
                    Button(action: edit) {
                        Icon("pencil", size: 12).foregroundStyle(Palette.secondary)
                            .frame(width: 16, height: 16).contentShape(Circle())
                    }
                    .buttonStyle(Pressable())
                    .accessibilityLabel("Edit")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                Button(action: remove) {
                    Icon("x", size: 12).foregroundStyle(hovering ? Palette.danger : Palette.muted)
                        .frame(width: 16, height: 16).contentShape(Circle())
                }
                .buttonStyle(Pressable())
                .accessibilityLabel("Delete")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, editing ? 12 : 8)
        .frame(height: 32)
        .background(editing ? Palette.field : Palette.card, in: Capsule())
        .overlay(Capsule().strokeBorder(refused ? Palette.danger : editing ? Palette.orange.opacity(0.6) : .clear, lineWidth: 1.5))
        .shadow(color: Palette.shadow.opacity(hovering && !editing ? 0.8 : 0.4), radius: hovering ? 6 : 3, y: 1)
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
        .motion(Motion.reveal, value: editing)
        .accessibilityElement(children: editing ? .contain : .combine)
        .accessibilityAction(named: Text("Edit"), edit)
        .onChange(of: SnapshotStage.shared.editingTerm, initial: true) { _, staged in
            guard let staged, staged.term == term else { return }
            edit()
            draft = staged.draft
        }
    }

    private func edit() {
        draft = term
        editing = true
        focused = true
    }

    /// Enter saves; an empty or unchanged spelling just ends editing, and a refused one stays open
    /// with its reason.
    private func save() {
        guard canRename(draft) else { return }
        rename(draft)
        editing = false
    }

    /// Clicking away saves like Finder's rename, but drops a refused spelling instead of trapping
    /// the user in the field. Esc has already ended editing, so it saves nothing.
    private func leave() {
        guard editing else { return }
        if canRename(draft) { rename(draft) }
        editing = false
    }

    private func cancel() {
        editing = false
    }
}
