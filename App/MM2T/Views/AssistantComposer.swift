import AppKit
import MM2TApp
import SwiftUI

struct AssistantComposer: View {
    @Bindable var model: AssistantModel
    @State private var focused = false
    @State private var height: CGFloat = 22

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Icon("sparkles", size: 17)
                .foregroundStyle(model.draft.isEmpty ? Palette.muted : Palette.orange)
                .padding(.bottom, 6)
            AssistantInput(text: $model.draft, focused: $focused, height: $height,
                submit: { model.send() }, leave: { if model.draft.isEmpty && !model.isRunning { model.isActive = false } })
                .frame(height: height)
                .overlay(alignment: .topLeading) {
                    if model.draft.isEmpty {
                        Text("Ask about your meetings")
                            .font(.system(size: 15, weight: .regular, design: .rounded))
                            .foregroundStyle(Palette.muted).padding(.top, 2).allowsHitTesting(false)
                    }
                }
                .padding(.vertical, 4)
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
        .modifier(PlaybackGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
        .shadow(color: Palette.shadow, radius: focused ? 26 : 18, y: focused ? 10 : 6)
        .motion(Motion.touch, value: focused)
    }
    private var canSend: Bool { model.isRunning || !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private struct AssistantInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    @Binding var height: CGFloat
    let submit: () -> Void
    let leave: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let editor = InputTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        editor.resized = { [weak coordinator = context.coordinator] editor in coordinator?.measure(editor) }
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 15).withRoundedDesign
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
        editor.setAccessibilityLabel(String(localized: "Ask about your meetings"))
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? InputTextView else { return }
        if editor.string != text && !editor.hasMarkedText() { editor.string = text }
        editor.textColor = NSColor(Palette.text)
        editor.submit = submit; editor.leave = leave
        context.coordinator.measure(editor)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AssistantInput
        init(_ parent: AssistantInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            measure(editor)
        }
        func measure(_ editor: NSTextView) {
            guard let container = editor.textContainer, let layout = editor.layoutManager else { return }
            layout.ensureLayout(for: container)
            let value = min(132, max(22, ceil(layout.usedRect(for: container).height)))
            if parent.height != value { DispatchQueue.main.async { self.parent.height = value } }
        }
    }
}

private final class InputTextView: NSTextView {
    var submit: () -> Void = {}
    var leave: () -> Void = {}
    var focusChanged: (Bool) -> Void = { _ in }
    var resized: (NSTextView) -> Void = { _ in }
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

private extension NSFont {
    var withRoundedDesign: NSFont {
        fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: pointSize) } ?? self
    }
}
