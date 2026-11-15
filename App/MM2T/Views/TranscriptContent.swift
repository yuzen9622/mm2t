import MM2TApp
import MM2TCore
import SwiftUI

struct TranscriptContent: View {
    let model: MeetingDetailModel
    let presentation: MeetingPresentation
    let playhead: Playhead
    /// Set when the user scrolls away while playing; the view stops following until they come back.
    @State private var followPaused = false

    var body: some View {
        let lines = lyricLines
        let current = playhead.currentLine
        let currentID = current.flatMap { index in
            lines.flatMap { $0.indices.contains(index) ? $0[index].id : nil }
        }
        ScrollViewReader { proxy in
            FadingScrollView {
                LazyVStack(alignment: .leading, spacing: lines == nil ? 10 : 2) {
                    switch model.selectedView {
                    case .raw, .cleaned:
                        if let lines { lyrics(lines, current: current) } else { NotGenerated() }
                    case .perPerson: perPerson
                    case .summary: summary
                    }
                }
                .padding(.bottom, 96)
                .id(model.selectedView)
                .transition(.opacity)
            }
            .modifier(ScrollInteraction { if playhead.isPlaying { followPaused = true } })
            .motion(Motion.reveal, value: model.selectedView)
            .onChange(of: lines, initial: true) { _, lines in
                playhead.follow(lines?.map(\.start) ?? [])
            }
            .onChange(of: model.focusedUtterance) { _, id in
                if let id { withAnimation(Motion.page) { proxy.scrollTo(id.rawValue, anchor: .center) } }
            }
            .onChange(of: currentID) { _, id in
                guard let id, playhead.isPlaying, !followPaused else { return }
                withAnimation(.smooth(duration: 0.6)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            }
            .onChange(of: playhead.isPlaying) { _, playing in if !playing { followPaused = false } }
            .overlay(alignment: .bottom) {
                if followPaused, playhead.isPlaying, let currentID {
                    PillButton("Back to Playback", icon: "player-play", kind: .primary) {
                        followPaused = false
                        withAnimation(.smooth(duration: 0.6)) { proxy.scrollTo(currentID, anchor: UnitPoint(x: 0.5, y: 0.3)) }
                    }
                    .padding(.bottom, 76)
                    .transition(.offset(y: 8).combined(with: .opacity))
                }
            }
            .motion(Motion.reveal, value: followPaused)
        }
    }

    /// The raw or cleaned transcript as timed lines; nil for the other views and for a cleaned
    /// transcript that has not been generated.
    private var lyricLines: [LyricLine]? {
        switch model.selectedView {
        case .raw:
            return presentation.raw.map {
                LyricLine(id: $0.id.rawValue, speakerName: $0.speakerName, start: $0.start, text: $0.text, isMarkdown: false,
                          isOverlapping: $0.isOverlapping, isHighlighted: $0.isHighlighted,
                          words: $0.words, spans: [TimeRange(start: $0.start, end: $0.end)])
            }
        case .cleaned:
            guard let rows = presentation.cleaned else { return nil }
            var previous: TimeInterval = 0
            return rows.map { row in
                previous = row.jump?.time ?? previous
                return LyricLine(id: row.id, speakerName: row.speakerName ?? "", start: previous, text: row.text, isMarkdown: true,
                                 spans: row.spans)
            }
        case .perPerson, .summary:
            return nil
        }
    }

    @ViewBuilder private func lyrics(_ lines: [LyricLine], current: Int?) -> some View {
        let raw = model.selectedView == .raw
        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
            let state = KaraokeTiming.state(of: index, current: current, isPlaying: playhead.isPlaying)
            LyricRow(line: line,
                     showsSpeaker: index == 0 || lines[index - 1].speakerName != line.speakerName,
                     state: state,
                     playhead: playhead,
                     isFocused: raw && model.focusedUtterance?.rawValue == line.id,
                     canEdit: model.canEditSpeakers,
                     play: {
                         followPaused = false
                         if raw, let row = presentation.raw.first(where: { $0.id.rawValue == line.id }) {
                             model.play(row)
                         } else {
                             model.play(at: line.start)
                         }
                     },
                     save: { text in
                         if raw {
                             Task { await model.edit(UtteranceID(line.id), to: text) }
                         } else if let row = presentation.cleaned?.first(where: { $0.id == line.id }) {
                             Task { await model.editCleaned(row, to: text) }
                         }
                     },
                     rewrite: raw ? nil : { text, instruction in try await model.rewrite(text, instruction: instruction) })
                .id(line.id)
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
            if !summary.actionItems.isEmpty {
                TodoSection(title: Copy.presentationLabels.actionItems, rows: summary.actionItems, model: model)
            }
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
    /// Rewrites the text the way an instruction asks ("make it more polite"); nil where it doesn't apply.
    var rewrite: ((String, String) async throws -> String)?
    @FocusState private var focused: Bool
    @State private var instruction = ""
    @State private var rewriting = false
    @State private var rewriteFailed = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if rewrite != nil { rewriteField }
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

    private var rewriteField: some View {
        HStack(spacing: 8) {
            Icon("sparkles", size: 14).foregroundStyle(Palette.orange)
            TextField("Tell AI how to change it, e.g. more polite", text: $instruction)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .onSubmit(runRewrite)
            if rewriting {
                ProgressView().controlSize(.small)
            } else {
                PillButton("Rewrite", action: runRewrite)
                    .disabled(instruction.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 38)
        .background(Palette.field, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if rewriteFailed {
                Text("Couldn't rewrite. Check the summary model in Settings.").font(Typo.caption).foregroundStyle(Palette.danger)
                    .offset(y: 18)
            }
        }
        .padding(.bottom, rewriteFailed ? 14 : 0)
    }

    private func runRewrite() {
        let ask = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rewrite, !ask.isEmpty, !rewriting else { return }
        rewriting = true
        rewriteFailed = false
        Task {
            do {
                text = try await rewrite(text, ask)
                instruction = ""
            } catch {
                rewriteFailed = true
            }
            rewriting = false
        }
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
        let text: AttributedString
    }

    private let blocks: [Block]
    private let font: Font
    private let karaoke: Karaoke?

    init(_ text: String, font: Font = Typo.body, karaoke: Karaoke? = nil) {
        self.font = font
        self.karaoke = karaoke
        blocks = text.split(separator: "\n", omittingEmptySubsequences: true).enumerated().map { index, line in
            let line = String(line)
            let match = line.wholeMatch(of: /\s*(\d+\.|[-*•])\s+(.+)/)
            let body = match.map { String($0.2) } ?? line
            let parsed = (try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(body)
            let marker = match.map { String($0.1) }.map { $0.first!.isNumber ? $0 : "•" }
            return Block(id: index, marker: marker, text: parsed)
        }
    }

    var body: some View {
        let texts = painted
        VStack(alignment: .leading, spacing: font == Typo.reading ? 8 : 4) {
            ForEach(blocks) { block in
                if let marker = block.marker {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).font(font).monospacedDigit().foregroundStyle(Palette.secondary)
                        inline(texts[block.id])
                    }
                } else {
                    inline(texts[block.id])
                }
            }
        }
        .textSelection(.enabled)
    }

    /// The blocks' text, lit up as far as playback has reached when this is the line being heard.
    private var painted: [AttributedString] {
        guard let karaoke else { return blocks.map(\.text) }
        let shown = blocks.map { String($0.text.characters) }.joined()
        let starts = karaoke.starts(shown)
        var offset = 0
        return blocks.map { block in
            var text = block.text
            offset = karaoke.paint(&text, starts: starts, from: offset)
            return text
        }
    }

    private func inline(_ text: AttributedString) -> some View {
        KaraokeText(text: text).font(font)
            .lineSpacing(font == Typo.reading ? Typo.readingLineSpacing : 0)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Calls `began` when the user starts scrolling by hand. Before macOS 15 there is no way to tell,
/// and the transcript always follows playback.
private struct ScrollInteraction: ViewModifier {
    let began: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollPhaseChange { _, phase in if phase == .interacting { began() } }
        } else {
            content
        }
    }
}
