import AppKit
import MM2TApp
import SwiftUI

struct InlineMeetingDocument: View {
    let markdown: String
    let editable: Bool
    let update: (String) -> Void

    /// Keep a stable reading layout while typing. Only the active source range is spliced
    /// into the original Markdown, including all of its untouched whitespace and definitions.
    private struct Edit: Identifiable {
        let id = UUID()
        let source: NSRange
        let display: NSRange
        let caret: Int
        let font: NSFont
        let spacingBefore: CGFloat
        let spacingAfter: CGFloat
    }

    @State private var layout: MeetingMarkdown.Layout?
    @State private var edit: Edit?
    @State private var buffer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                if edit != nil {
                    PillButton("Done", icon: "check", action: finish)
                        .keyboardShortcut(.return, modifiers: .command)
                } else {
                    PillButton("Edit Markdown", icon: "pencil") {
                        guard let layout else { return }
                        activate(layout, source: NSRange(location: 0, length: (layout.source as NSString).length),
                                 display: NSRange(location: 0, length: layout.preview.length), caret: 0, font: readingFont)
                    }.disabled(!editable)
                }
            }
            .padding(.bottom, 16)
            if let layout {
                if let edit {
                    preview(layout, from: 0, to: edit.display.location)
                    SourceField(text: buffer, caret: edit.caret, font: edit.font, changed: { text in
                        guard self.edit?.id == edit.id, buffer != text else { return }
                        buffer = text
                        update(replacing(edit, in: layout, with: text))
                    }, finish: finish)
                    .id(edit.id)
                    .padding(.top, edit.spacingBefore)
                    .padding(.bottom, edit.spacingAfter)
                    preview(layout, from: NSMaxRange(edit.display), to: layout.preview.length)
                } else {
                    preview(layout, from: 0, to: layout.preview.length)
                }
            }
        }
        .onChange(of: markdown, initial: true) {
            if let layout {
                let current = edit.map { replacing($0, in: layout, with: buffer) } ?? layout.source
                if current == markdown { return }
            }
            show(markdown)
        }
        .onChange(of: editable) { if !editable { finish() } }
    }

    private var readingFont: NSFont { .systemFont(ofSize: Typo.readingSize) }

    private func show(_ source: String) {
        edit = nil
        layout = MeetingMarkdown.layout(source, style: .meetingDocument)
    }

    private func replacing(_ edit: Edit, in layout: MeetingMarkdown.Layout, with text: String) -> String {
        (layout.source as NSString).replacingCharacters(in: edit.source, with: text)
    }

    private func finish() {
        if let edit, let layout { show(replacing(edit, in: layout, with: buffer)) }
    }

    @ViewBuilder private func preview(_ layout: MeetingMarkdown.Layout, from start: Int, to end: Int) -> some View {
        if end > start || (edit == nil && layout.preview.length == 0) {
            let string = layout.preview.string as NSString
            let hasSeparator = end < string.length && end > start && string.character(at: end - 1) == 10
            let paragraph = hasSeparator ? layout.preview.attribute(.paragraphStyle, at: end - 1, effectiveRange: nil) as? NSParagraphStyle : nil
            // A table needs its terminating cell paragraph. Other preview slices end at the
            // last visible character, so an extra empty line does not move the clicked heading.
            let limit = hasSeparator && paragraph?.textBlocks.isEmpty == true ? end - 1 : end
            DocumentPreview(document: layout.preview, range: NSRange(location: start, length: limit - start),
                            editable: editable, clicked: { openBlock(in: layout, at: start + $0, limit: end) })
        }
    }

    private func openBlock(in previous: MeetingMarkdown.Layout, at index: Int, limit: Int) {
        let hit = min(index, max(0, limit - 1))
        guard editable, let old = previous.blocks.last(where: { $0.display.location <= hit }) else { return }
        var current = previous
        var insertion = old.source.location + previous.caret(at: index, in: old)
        if let edit {
            let source = replacing(edit, in: previous, with: buffer)
            if source != previous.source {
                if old.source.location >= NSMaxRange(edit.source) { insertion += (buffer as NSString).length - edit.source.length }
                current = MeetingMarkdown.layout(source, style: .meetingDocument)
            }
        }
        guard let block = current.blocks.last(where: { $0.source.location <= insertion }) ?? current.blocks.first else { return }
        let caret = min(max(0, insertion - block.source.location), block.source.length)
        let font = block.display.length > 0
            ? current.preview.attribute(.font, at: block.display.location, effectiveRange: nil) as? NSFont : nil
        activate(current, source: block.source, display: block.display, caret: caret, font: font ?? readingFont)
    }

    private func activate(_ current: MeetingMarkdown.Layout, source: NSRange, display: NSRange, caret: Int, font: NSFont) {
        layout = current
        buffer = (current.source as NSString).substring(with: source)
        let paragraph = display.length > 0 ? current.preview.attribute(.paragraphStyle, at: display.location, effectiveRange: nil) as? NSParagraphStyle : nil
        edit = Edit(source: source, display: display, caret: caret, font: font,
                    spacingBefore: display.location == 0 ? 0 : paragraph?.paragraphSpacingBefore ?? 0,
                    spacingAfter: paragraph?.paragraphSpacing ?? 0)
    }
}

private class PageTextView: NSTextView {
    func configurePage() {
        drawsBackground = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
    }

    func fittedSize(_ proposal: ProposedViewSize) -> CGSize? {
        guard let width = proposal.width, width.isFinite, let textContainer, let layoutManager else { return nil }
        textContainer.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let height = max(layoutManager.usedRect(for: textContainer).maxY, layoutManager.extraLineFragmentUsedRect.maxY)
        return CGSize(width: width, height: max(24, ceil(height)))
    }
}

private struct DocumentPreview: NSViewRepresentable {
    let document: NSAttributedString
    let range: NSRange
    let editable: Bool
    let clicked: (Int) -> Void

    final class Preview: PageTextView {
        var document: NSAttributedString?
        var range: NSRange?
        var clicked: ((Int) -> Void)?

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            if let clicked, !event.modifierFlags.contains(.command) {
                clicked(min(index, (string as NSString).length))
            } else {
                super.mouseDown(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> Preview {
        let view = Preview()
        view.configurePage()
        view.isEditable = false
        view.isSelectable = true
        view.linkTextAttributes = [.foregroundColor: NSColor(Palette.orange), .underlineStyle: NSUnderlineStyle.single.rawValue]
        return view
    }

    func updateNSView(_ view: Preview, context: Context) {
        view.clicked = editable ? clicked : nil
        guard view.document !== document || view.range != range else { return }
        view.document = document
        view.range = range
        view.textStorage?.setAttributedString(document.attributedSubstring(from: range))
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Preview, context: Context) -> CGSize? { nsView.fittedSize(proposal) }
}

private struct SourceField: NSViewRepresentable {
    let text: String
    let caret: Int
    let font: NSFont
    let changed: (String) -> Void
    let finish: () -> Void

    final class Editor: PageTextView {
        var changed: ((String) -> Void)?
        var finish: (() -> Void)?
        var initialCaret: Int?
        private let history = UndoManager()
        override var undoManager: UndoManager? { history }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, let initialCaret {
                self.initialCaret = nil
                window.makeFirstResponder(self)
                setSelectedRange(NSRange(location: initialCaret, length: 0))
            }
        }

        func publish() {
            guard !hasMarkedText() else { return }
            if let layoutManager {
                let full = NSRange(location: 0, length: (string as NSString).length)
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
                let hashes = string.prefix { $0 == "#" }.count
                if (1...6).contains(hashes), string.dropFirst(hashes).first == " " {
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor(Palette.secondary),
                                                        forCharacterRange: NSRange(location: 0, length: hashes))
                }
            }
            changed?(string)
        }

        override func didChangeText() {
            super.didChangeText()
            invalidateIntrinsicContentSize()
            publish()
        }

        override func unmarkText() {
            super.unmarkText()
            publish()
        }

        override func cancelOperation(_ sender: Any?) {
            if hasMarkedText() { super.cancelOperation(sender) } else { finish?() }
        }
    }

    func makeNSView(context: Context) -> Editor {
        let view = Editor()
        view.configurePage()
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.font = font
        view.textColor = NSColor(Palette.text)
        view.insertionPointColor = NSColor(Palette.orange)
        view.defaultParagraphStyle = {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = Typo.readingLineSpacing
            return paragraph
        }()
        view.string = text
        view.initialCaret = caret
        view.setAccessibilityLabel(String(localized: "Edit Markdown"))
        view.publish()
        return view
    }

    func updateNSView(_ view: Editor, context: Context) {
        view.changed = changed
        view.finish = finish
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Editor, context: Context) -> CGSize? { nsView.fittedSize(proposal) }
}
