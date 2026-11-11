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
            UtteranceView(row: row, isFocused: row.id == model.focusedUtterance) { model.play(row) }
                .id(row.id)
        }
    }

    @ViewBuilder private var cleaned: some View {
        if let rows = presentation.cleaned {
            ForEach(rows) { SourcedRowView(row: $0, model: model, showsSpeaker: true).card() }
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

struct UtteranceView: View {
    let row: UtteranceRow
    let isFocused: Bool
    let play: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: play) {
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
                    Text(row.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isFocused ? Palette.orangeSoft : hovering ? Palette.hover : .clear,
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
        .motion(Motion.select, value: isFocused)
    }
}

/// A generated item; selecting it jumps to its source utterance and plays from there (story 51).
struct SourcedRowView: View {
    let row: SourcedRow
    let model: MeetingDetailModel
    let showsSpeaker: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            if let jump = row.jump { model.jump(to: jump) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if showsSpeaker, let name = row.speakerName { Avatar(name: name, isNamed: true) }
                Text(row.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let jump = row.jump {
                    Text(MeetingPresentation.timestamp(jump.time)).font(Typo.caption).monospacedDigit()
                        .foregroundStyle(hovering ? Palette.orange : Palette.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .disabled(row.jump == nil)
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
    }
}

struct NotGenerated: View {
    var body: some View {
        Text(Copy.presentationLabels.notGenerated).foregroundStyle(Palette.secondary).card()
    }
}
