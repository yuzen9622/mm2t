import MM2TApp
import MM2TCore
import SwiftUI

struct TranscriptContent: View {
    let model: MeetingDetailModel
    let presentation: MeetingPresentation

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    switch model.selectedView {
                    case .raw: raw
                    case .cleaned: cleaned
                    case .perPerson: perPerson
                    case .summary: summary
                    }
                }
                .padding(.bottom, 24)
                .id(model.selectedView)
                .transition(.opacity)
            }
            .motion(Motion.reveal, value: model.selectedView)
            .onChange(of: model.focusedUtterance) { _, id in
                if let id { withAnimation(Motion.page) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    @ViewBuilder private var raw: some View {
        ForEach(presentation.raw) { row in
            UtteranceView(row: row, isFocused: row.id == model.focusedUtterance, canEdit: model.canEditSpeakers,
                          play: { model.play(row) }, save: { text in Task { await model.edit(row.id, to: text) } })
                .id(row.id)
        }
    }

    @ViewBuilder private var cleaned: some View {
        if let rows = presentation.cleaned {
            ForEach(rows) { row in
                SourcedRowView(row: row, model: model, showsSpeaker: true,
                               save: model.canEditSpeakers ? { text in Task { await model.editCleaned(row, to: text) } } : nil)
                    .card()
            }
        } else {
            NotGenerated()
        }
    }

    @ViewBuilder private var perPerson: some View {
        if let digests = presentation.digests {
            ForEach(digests) { digest in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Avatar(name: digest.speakerName, isNamed: true)
                        Text(digest.speakerName).font(Typo.heading)
                    }
                    ForEach(digest.points) { SourcedRowView(row: $0, model: model, showsSpeaker: false) }
                }
                .card()
            }
        } else {
            NotGenerated()
        }
    }

    @ViewBuilder private var summary: some View {
        if let summary = presentation.summary {
            section(Copy.presentationLabels.decisions, summary.decisions, speakers: false)
            section(Copy.presentationLabels.discussionPoints, summary.discussionPoints, speakers: false)
            section(Copy.presentationLabels.actionItems, summary.actionItems, speakers: true)
        } else {
            NotGenerated()
        }
    }

    @ViewBuilder private func section(_ title: String, _ rows: [SourcedRow], speakers: Bool) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(Typo.captionStrong).foregroundStyle(Palette.secondary)
                ForEach(rows) { SourcedRowView(row: $0, model: model, showsSpeaker: speakers) }
            }
            .card()
        }
    }
}

/// A line of text the user is correcting, with the two ways out of it.
struct TextCorrection: View {
    @State var text: String
    let save: (String) -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("Correction", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .focused($focused)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Palette.field, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.orange.opacity(0.6), lineWidth: 1.5))
                .onExitCommand(perform: cancel)
            HStack(spacing: 8) {
                PillButton("Cancel", action: cancel)
                PillButton("Save", kind: .primary) { save(text) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { focused = true }
    }
}

struct UtteranceView: View {
    let row: UtteranceRow
    let isFocused: Bool
    let canEdit: Bool
    let play: () -> Void
    let save: (String) -> Void
    @State private var hovering = false
    @State private var editing = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: row.speakerName, isNamed: true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.speakerName).font(Typo.bodyStrong)
                    Text(MeetingPresentation.timestamp(row.start)).font(Typo.caption).monospacedDigit().foregroundStyle(Palette.secondary)
                    if row.isOverlapping {
                        Text("Overlapping").font(Typo.caption).foregroundStyle(Palette.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 1).background(Palette.field, in: Capsule())
                    }
                    if row.isHighlighted { Icon("star-filled", size: 13).foregroundStyle(Palette.orange) }
                }
                if editing {
                    TextCorrection(text: row.text, save: { save($0); editing = false }, cancel: { editing = false })
                } else {
                    Text(row.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if canEdit, !editing {
                IconButton("Edit", icon: "pencil") { editing = true }
                    .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isFocused ? Palette.orangeSoft : hovering ? Palette.hover : .clear,
                    in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if !editing { play() } }
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
        .motion(Motion.select, value: isFocused)
        .motion(Motion.reveal, value: editing)
    }
}

/// A generated item; selecting it jumps to its source utterance and plays from there (story 51).
/// `save` makes the text correctable, which only the cleaned transcript is.
struct SourcedRowView: View {
    let row: SourcedRow
    let model: MeetingDetailModel
    let showsSpeaker: Bool
    var save: ((String) -> Void)?
    @State private var hovering = false
    @State private var editing = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsSpeaker, let name = row.speakerName { Avatar(name: name, isNamed: true) }
            if editing, let save {
                TextCorrection(text: row.text, save: { save($0); editing = false }, cancel: { editing = false })
            } else {
                MarkdownText(row.text)
                Spacer(minLength: 8)
                if save != nil {
                    IconButton("Edit", icon: "pencil") { editing = true }
                        .opacity(hovering ? 1 : 0)
                }
                if let jump = row.jump {
                    Text(MeetingPresentation.timestamp(jump.time)).font(Typo.caption).monospacedDigit()
                        .foregroundStyle(hovering ? Palette.orange : Palette.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !editing, let jump = row.jump { model.jump(to: jump) } }
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
        .motion(Motion.reveal, value: editing)
    }
}

struct NotGenerated: View {
    var body: some View {
        Text(Copy.presentationLabels.notGenerated).foregroundStyle(Palette.secondary).card()
    }
}

/// Text from the model, shown as Markdown: numbered and bulleted lines become an aligned list
/// (SwiftUI's own Markdown handles inline styling but flattens lists), other lines stay paragraphs.
struct MarkdownText: View {
    private struct Block: Identifiable {
        let id: Int
        let marker: String?
        let text: String
    }

    private let blocks: [Block]

    init(_ text: String) {
        blocks = text.split(separator: "\n", omittingEmptySubsequences: true).enumerated().map { index, line in
            let line = String(line)
            guard let match = line.wholeMatch(of: /\s*(\d+\.|[-*•])\s+(.+)/) else {
                return Block(id: index, marker: nil, text: line)
            }
            let marker = String(match.1)
            return Block(id: index, marker: marker.first!.isNumber ? marker : "•", text: String(match.2))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(blocks) { block in
                if let marker = block.marker {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).monospacedDigit().foregroundStyle(Palette.secondary)
                        inline(block.text)
                    }
                } else {
                    inline(block.text)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> some View {
        let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return Text(attributed ?? AttributedString(text)).fixedSize(horizontal: false, vertical: true)
    }
}
