import MM2TApp
import MM2TCore
import SwiftUI

typealias Playhead = TranscriptPlayhead

/// How a line reads against the playhead, the way synced lyrics do: what is still to come is faint,
/// what has been heard is back to full strength, and the line being heard is marked.
typealias LyricState = KaraokeTiming.LineState

/// A timed passage of the raw or cleaned transcript.
struct LyricLine: Identifiable, Equatable {
    let id: String
    let speakerName: String
    let start: TimeInterval
    let text: String
    /// Cleaned text is Markdown (lists); raw text is shown as it was heard.
    let isMarkdown: Bool
    var isOverlapping = false
    var isHighlighted = false
    /// The speech service's word times; empty for rewritten text.
    var words: [TimedWord] = []
    /// When the line's speech was spoken, for text without word times of its own.
    var spans: [TimeRange] = []

    var end: TimeInterval { spans.last?.end ?? words.last?.range.end ?? start }

}

/// Lights up a line character by character as it is heard: what has been said is at full strength,
/// the character being said brightens as it goes, and the rest waits faint.
struct Karaoke {
    static let faint = 0.34

    let line: LyricLine
    let now: TimeInterval
    var reduceMotion = false

    func starts(_ shown: String) -> [TimeInterval] {
        KaraokeTiming.starts(of: shown, words: line.words, spans: line.spans)
    }

    /// Colours the non-whitespace characters of `text`, counting from `first`; returns the count after it.
    func paint(_ text: inout AttributedString, starts: [TimeInterval], from first: Int) -> Int {
        let (heard, fraction) = KaraokeTiming.progress(starts, end: line.end, at: now)
        var counted = first
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.characters.index(after: index)
            if !text.characters[index].isWhitespace {
                let progress = counted < heard ? 1 : counted == heard ? fraction : 0
                let strength = Self.faint + (1 - Self.faint) * progress
                text[index..<next].foregroundColor = Palette.text.opacity(strength)
                let settled = progress * progress * (3 - 2 * progress)
                text[index..<next][KaraokeBlur.self] = 0.7 * (1 - settled)
                if !reduceMotion {
                    text[index..<next][KaraokeLift.self] = -2 * (1 - settled)
                }
                counted += 1
            }
            index = next
        }
        return counted
    }
}

private enum KaraokeLift: AttributedStringKey {
    typealias Value = Double
    static let name = "mm2t.karaokeLift"
}

private enum KaraokeBlur: AttributedStringKey {
    typealias Value = Double
    static let name = "mm2t.karaokeBlur"
}

struct KaraokeText: View {
    let text: AttributedString

    var body: some View {
        if #available(macOS 15, *), text.runs.contains(where: { $0[KaraokeBlur.self] != nil }) {
            rendered.textRenderer(KaraokeRenderer())
        } else {
            Text(text)
        }
    }

    @available(macOS 15, *)
    private var rendered: Text {
        text.runs.reduce(Text(verbatim: "")) { result, run in
            let part = Text(AttributedString(text[run.range]))
                .customAttribute(KaraokeAttribute(lift: run[KaraokeLift.self] ?? 0, blur: run[KaraokeBlur.self] ?? 0))
            return result + part
        }
    }
}

@available(macOS 15, *)
private struct KaraokeAttribute: TextAttribute {
    let lift: Double
    let blur: Double
}

@available(macOS 15, *)
private struct KaraokeRenderer: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                var drawing = context
                let style = run[KaraokeAttribute.self]
                drawing.translateBy(x: 0, y: -(style?.lift ?? 0))
                if let blur = style?.blur, blur > 0 {
                    drawing.addFilter(.blur(radius: blur))
                }
                drawing.draw(run)
            }
        }
    }
}

struct LyricRow: View {
    let line: LyricLine
    let showsSpeaker: Bool
    let state: LyricState
    let playhead: Playhead
    let isFocused: Bool
    let canEdit: Bool
    let play: () -> Void
    let save: (String) -> Void
    var rewrite: ((String, String) async throws -> String)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsSpeaker {
                HStack(spacing: 8) {
                    Avatar(name: line.speakerName, isNamed: true, size: 22)
                    Text(line.speakerName).font(Typo.captionStrong).foregroundStyle(Palette.secondary)
                    if line.isOverlapping {
                        Text("Overlapping").font(Typo.caption).foregroundStyle(Palette.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 1).background(Palette.field, in: Capsule())
                    }
                }
                .padding(.top, 18)
                .padding(.leading, 14)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if editing {
                    TextCorrection(text: line.text, save: { save($0); editing = false }, cancel: { editing = false },
                                   rewrite: rewrite)
                } else {
                    content
                        .foregroundStyle(Palette.text)
                    Spacer(minLength: 8)
                    trailing
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(state == .current || isFocused ? Palette.orangeSoft : hovering ? Palette.hover : .clear)
            }
            .overlay(alignment: .leading) {
                Capsule().fill(Palette.orange).frame(width: 3).padding(.vertical, 9)
                    .opacity(state == .current ? 1 : 0)
                    .scaleEffect(y: state == .current ? 1 : 0.4)
            }
            .contentShape(Rectangle())
            .onTapGesture { if !editing { play() } }
            .onHover { hovering = $0 }
        }
        // About 45 characters of Chinese a line: long enough to read in phrases, short enough to track.
        .frame(maxWidth: 760, alignment: .leading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: state)
        .motion(Motion.touch, value: hovering)
        .motion(Motion.reveal, value: editing)
    }

    @ViewBuilder private var content: some View {
        let karaoke = state == .current || state == .upcoming
            ? Karaoke(line: line, now: state == .upcoming ? -.infinity : playhead.time, reduceMotion: reduceMotion)
            : nil
        if line.isMarkdown {
            MarkdownText(line.text, font: Typo.reading, karaoke: karaoke)
        } else {
            KaraokeText(text: karaoke.map { karaoke in
                var text = AttributedString(line.text)
                _ = karaoke.paint(&text, starts: karaoke.starts(line.text), from: 0)
                return text
            } ?? AttributedString(line.text))
                .font(Typo.reading)
                .lineSpacing(Typo.readingLineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var trailing: some View {
        HStack(spacing: 6) {
            if line.isHighlighted { Icon("star-filled", size: 12).foregroundStyle(Palette.orange) }
            if canEdit {
                IconButton("Edit", icon: "pencil") { editing = true }
                    .opacity(hovering ? 1 : 0)
            }
            Text(MeetingPresentation.timestamp(line.start))
                .font(Typo.caption).monospacedDigit()
                .foregroundStyle(state == .current ? Palette.orange : Palette.muted)
                .opacity(hovering || state == .current ? 1 : 0.0)
        }
    }
}

/// Play or pause, where the playhead is, and a bar to drag it along.
struct TransportBar: View {
    let playhead: Playhead
    var status: PlaybackStatus = .ready
    let toggle: () -> Void
    let seek: (TimeInterval) -> Void
    @State private var dragging: Double?
    @State private var isScrubbing = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Group {
                    if status == .loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Icon(playhead.isPlaying ? "player-pause-filled" : "player-play-filled", size: 15)
                    }
                }
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Palette.orange, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(Pressable())
            .keyboardShortcut(.space, modifiers: [])
            .disabled(status != .ready)
            .accessibilityLabel(playhead.isPlaying ? "Pause" : "Play")
            .help(playhead.isPlaying ? "Pause" : "Play")
            Text(MeetingPresentation.timestamp(shown)).font(Typo.caption).monospacedDigit().foregroundStyle(Palette.secondary)
                .frame(minWidth: 44, alignment: .trailing)
            if status == .unavailable {
                Text("Audio unavailable").font(Typo.caption).frame(maxWidth: .infinity)
            } else if status == .failed {
                Text("Couldn't load audio").font(Typo.caption).frame(maxWidth: .infinity)
            } else {
                track
                    .opacity(status == .ready ? 1 : 0.5)
                    .help(status == .loading ? "Preparing audio…" : "Playback position")
            }
            Text(MeetingPresentation.timestamp(playhead.duration)).font(Typo.caption).monospacedDigit().foregroundStyle(Palette.muted)
                .frame(minWidth: 44, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
        .modifier(PlaybackGlass())
        .onChange(of: status) {
            dragging = nil
            isScrubbing = false
        }
        .shadow(color: Palette.shadow, radius: 12, y: 3)
    }

    private var shown: TimeInterval { dragging.map { $0 * playhead.duration } ?? playhead.time }

    private var fraction: Double {
        guard playhead.duration > 0 else { return 0 }
        return dragging ?? min(1, max(0, playhead.time / playhead.duration))
    }

    private var track: some View {
        Slider(value: Binding(get: { fraction }, set: { value in
            guard status == .ready else { return }
            if isScrubbing {
                dragging = value
            } else {
                seek(value * playhead.duration)
            }
        }), in: 0...1, onEditingChanged: { editing in
            isScrubbing = editing
            if !editing {
                if let dragging, status == .ready { seek(dragging * playhead.duration) }
                dragging = nil
            }
        }) {
            Text("Playback position")
        }
        .labelsHidden()
        .tint(Palette.orange)
        .frame(height: 24)
        .disabled(status != .ready || playhead.duration <= 0)
        .focusEffectDisabled()
        .accessibilityValue(MeetingPresentation.timestamp(shown))
    }
}

private struct PlaybackGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Palette.card, in: Capsule())
        } else if #available(macOS 26, *) {
            content
                .background(Palette.card.opacity(0.45), in: Capsule())
                .glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5) }
        }
    }
}
