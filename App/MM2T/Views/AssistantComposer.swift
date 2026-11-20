import AppKit
import CoreText
import MM2TApp
import MM2TCore
import SwiftUI

struct AssistantComposer: View {
    @Environment(FilingDragState.self) private var filingDrag
    @Bindable var model: AssistantModel
    @State private var focused = false
    @State private var hasMarkedText = false
    @State private var height = InputTextView.singleLineHeight

    private var showsPlaceholder: Bool {
        AssistantModel.showsPlaceholder(draft: model.draft, hasMarkedText: hasMarkedText)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Icon("sparkles", size: 17)
                .foregroundStyle(showsPlaceholder ? Palette.muted : Palette.orange)
                .frame(height: 30)
            AssistantInput(text: $model.draft, references: $model.draftReferences, focused: $focused, height: $height, hasMarkedText: $hasMarkedText,
                submit: { model.send() }, leave: { if model.draft.isEmpty && !model.isRunning { model.isActive = false } })
                .frame(height: height)
                .padding(.vertical, max(0, (30 - InputTextView.singleLineHeight) / 2))
                .frame(minHeight: 30)
            Button { if model.isRunning { model.stop() } else { model.send() } } label: {
                Icon(model.isRunning ? "player-stop" : "arrow-up", size: 14)
                    .id(model.isRunning)
                    .transition(.opacity)
                    .foregroundStyle(canSend ? .white : Palette.muted)
                    .frame(width: 30, height: 30)
                    .background(canSend ? Palette.orange : Palette.field, in: Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(!canSend)
            .accessibilityLabel(model.isRunning ? "Stop" : "Send")
            .motion(Motion.touch, value: model.isRunning)
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .filingTarget(.composer)
        .modifier(PlaybackGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
        .overlay {
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            ZStack {
                shape.fill(Palette.orange.opacity(0.07))
                shape.strokeBorder(Palette.orange.opacity(0.55), lineWidth: 5)
                    .blur(radius: 5).clipShape(shape)
                shape.strokeBorder(Palette.orange.opacity(0.9), lineWidth: 1.5)
            }
            .opacity(filingDrag.hovered == .composer ? 1 : 0)
            .motion(Motion.touch, value: filingDrag.hovered == .composer)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
        .shadow(color: Palette.shadow, radius: focused ? 26 : 18, y: focused ? 10 : 6)
        .motion(Motion.touch, value: focused)
    }
    private var canSend: Bool { model.isRunning || !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private struct AssistantInput: NSViewRepresentable {
    @Binding var text: String
    @Environment(FilingDragState.self) private var drag
    @Binding var references: Set<MeetingID>
    @Binding var focused: Bool
    @Binding var height: CGFloat
    @Binding var hasMarkedText: Bool
    @Environment(\.locale) private var locale
    let submit: () -> Void
    let leave: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let editor = InputTextView(frame: NSRect(x: 0, y: 0, width: 300, height: InputTextView.singleLineHeight))
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        editor.resized = { [weak coordinator = context.coordinator] editor in coordinator?.measure(editor) }
        editor.isRichText = false
        drag.insertReference = { [weak editor] item in
            guard let editor, let window = editor.window else { return }
            editor.insertReferences([item], at: editor.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.drawsBackground = false
        editor.font = InputTextView.inputFont
        editor.textColor = NSColor(Palette.text)
        editor.insertionPointColor = NSColor(Palette.orange)
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.submit = submit
        editor.leave = leave
        editor.focusChanged = { focused = $0 }
        editor.markedTextChanged = { [weak coordinator = context.coordinator, weak editor] marked in
            guard let coordinator, let editor else { return }
            DispatchQueue.main.async { coordinator.parent.hasMarkedText = marked }
            coordinator.textChanged(editor)
        }
        editor.placeholder = String(localized: "Ask about your meetings", locale: locale)
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? InputTextView else { return }
        if editor.composed.text != text && !editor.hasMarkedText() { editor.string = text }
        editor.placeholder = String(localized: "Ask about your meetings", locale: locale)
        editor.needsDisplay = true
        editor.submit = submit; editor.leave = leave
        context.coordinator.measure(editor)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AssistantInput
        init(_ parent: AssistantInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? InputTextView, !editor.isUpdatingInput else { return }
            textChanged(editor)
        }
        func textChanged(_ editor: InputTextView) {
            editor.needsDisplay = true
            if !editor.hasMarkedText() { let content = editor.composed; parent.references = content.ids; parent.text = content.text }
            measure(editor)
        }
        func measure(_ editor: NSTextView) {
            guard let container = editor.textContainer, let layout = editor.layoutManager else { return }
            layout.ensureLayout(for: container)
            let lineHeight = layout.defaultLineHeight(for: editor.font ?? InputTextView.inputFont)
            let contentHeight = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
            let value = min(132, max(ceil(lineHeight), ceil(contentHeight)))
            if parent.height != value { DispatchQueue.main.async { self.parent.height = value } }
        }
    }
}

private final class InputTextView: NSTextView {
    var composed: (text: String, ids: Set<MeetingID>) {
        guard let storage = textStorage else { return (string, []) }
        var text = "", ids = Set<MeetingID>()
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let reference = value as? ReferenceAttachment {
                text += reference.meeting.title; ids.insert(reference.meeting.id)
            } else { text += (storage.string as NSString).substring(with: range) }
        }
        return (text, ids)
    }
    func insertReferences(_ meetings: [MeetingDrag], at location: NSPoint) {
        let index = characterIndexForInsertion(at: location)
        guard let storage = textStorage else { return }
        var position = index
        for meeting in meetings {
            storage.insert(NSAttributedString(attachment: ReferenceAttachment(meeting)), at: position); position += 1
        }
        setSelectedRange(NSRange(location: position, length: 0)); window?.makeFirstResponder(self)
        typingAttributes = [.font: Self.inputFont, .foregroundColor: NSColor(Palette.text)]
        didChangeText()
    }
    static var inputFont: NSFont { .systemFont(ofSize: 15).withRoundedDesign }
    static var singleLineHeight: CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: inputFont)) }

    var placeholder = "" {
        didSet {
            setAccessibilityLabel(placeholder)
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard AssistantModel.showsPlaceholder(draft: string, hasMarkedText: hasMarkedText()),
              let font else { return }
        (placeholder as NSString).draw(at: textContainerOrigin, withAttributes: [
            .font: font, .foregroundColor: NSColor(Palette.muted),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    var submit: () -> Void = {}
    var leave: () -> Void = {}
    var focusChanged: (Bool) -> Void = { _ in }
    var markedTextChanged: (Bool) -> Void = { _ in }
    var resized: (NSTextView) -> Void = { _ in }
    private var inputUpdateDepth = 0
    var isUpdatingInput: Bool { inputUpdateDepth > 0 }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        inputUpdateDepth += 1
        defer { finishInputUpdate() }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    override func unmarkText() {
        inputUpdateDepth += 1
        defer { finishInputUpdate() }
        super.unmarkText()
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        inputUpdateDepth += 1
        defer { finishInputUpdate() }
        super.insertText(string, replacementRange: replacementRange)
    }
    private func finishInputUpdate() {
        inputUpdateDepth -= 1
        if !isUpdatingInput { markedTextChanged(hasMarkedText()) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resized(self)
    }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText() {
            if (event.keyCode == 36 || event.keyCode == 76) && !event.modifierFlags.contains(.shift) {
                submit(); return
            }
            if event.keyCode == 53 { leave(); return }
        }
        super.keyDown(with: event)
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusChanged(true) }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusChanged(false) }
        return result
    }
}

private final class ReferenceAttachment: NSTextAttachment {
    let meeting: MeetingDrag
    @MainActor init(_ meeting: MeetingDrag) {
        self.meeting = meeting
        super.init(data: nil, ofType: nil)
        let font = InputTextView.inputFont
        let tint = NSColor(Palette.orange)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
        let title = CTLineCreateWithAttributedString(NSAttributedString(string: meeting.title, attributes: attributes))
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let line = CTLineCreateTruncatedLine(title, 260, .end, ellipsis) ?? title
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let baseline = ceil(-font.descender)
        let side: CGFloat = 15
        let size = NSSize(width: 20 + ceil(CTLineGetTypographicBounds(line, nil, nil, nil)) + 3,
                          height: ceil(font.ascender - font.descender + font.leading))
        let icon = Bundle.main.url(forResource: "file-text", withExtension: "svg").flatMap(NSImage.init(contentsOf:))
        let image = NSImage(size: size, flipped: false) { _ in
            let iconRect = NSRect(x: 1, y: (baseline + ink.midY - side / 2).rounded(), width: side, height: side)
            icon?.draw(in: iconRect)
            tint.setFill(); iconRect.fill(using: .sourceAtop)
            if let context = NSGraphicsContext.current?.cgContext {
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: 20, y: baseline)
                CTLineDraw(line, context)
            }
            return true
        }
        let cell = NSTextAttachmentCell(imageCell: image)
        cell.setAccessibilityLabel(meeting.title)
        attachmentCell = cell
    }
    required init?(coder: NSCoder) { nil }
}

private extension NSFont {
    var withRoundedDesign: NSFont {
        fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: pointSize) } ?? self
    }
}
