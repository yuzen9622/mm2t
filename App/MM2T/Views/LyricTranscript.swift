import MM2TApp
import MM2TCore
import SwiftUI

/// Where playback is, sampled by the meeting view about ten times a second while it plays.
struct Playhead: Equatable {
    var time: TimeInterval = 0
    var duration: TimeInterval = 0
    var isPlaying = false
    /// Set the first time anything plays, so a meeting nobody has listened to reads at full strength.
    var started = false
}

/// How a line reads against the playhead, the way synced lyrics do: what is still to come is faint,
/// what has been heard is back to full strength, and the line being heard is marked.
enum LyricState: Equatable {
    case idle, played, current, upcoming
}

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

    /// The line being heard at `time`: the last one that has started. Between two lines the
    /// earlier one stays current, so the mark never blinks off during a pause.
    static func current(in lines: [LyricLine], at time: TimeInterval) -> Int? {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].start <= time + 0.05 { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    static func state(of index: Int, current: Int?, playhead: Playhead) -> LyricState {
        guard playhead.started, let current else { return playhead.started ? .upcoming : .idle }
        if index == current { return .current }
        return index < current ? .played : .upcoming
    }
}

/// Lights up a line character by character as it is heard: what has been said is at full strength,
/// the character being said brightens as it goes, and the rest waits faint.
struct Karaoke {
    static let faint = 0.34

    let line: LyricLine
    let now: TimeInterval

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
                let strength = counted < heard ? 1 : counted == heard ? Self.faint + (1 - Self.faint) * fraction : Self.faint
                text[index..<next].foregroundColor = Palette.text.opacity(strength)
                counted += 1
            }
            index = next
        }
        return counted
    }
}

struct LyricRow: View {
    let line: LyricLine
    let showsSpeaker: Bool
    let state: LyricState
    /// The playhead, given only to the line being heard, so the others don't redraw as it moves.
    var now: TimeInterval?
    let isFocused: Bool
    let canEdit: Bool
    let play: () -> Void
    let save: (String) -> Void
    var rewrite: ((String, String) async throws -> String)?
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
                        .opacity(state == .upcoming ? Karaoke.faint : 1)
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
        .animation(.easeInOut(duration: 0.45), value: state)
        .motion(Motion.touch, value: hovering)
        .motion(Motion.reveal, value: editing)
    }

    @ViewBuilder private var content: some View {
        let karaoke = state == .current ? now.map { Karaoke(line: line, now: $0) } : nil
        if line.isMarkdown {
            MarkdownText(line.text, font: Typo.reading, karaoke: karaoke)
        } else {
            Text(karaoke.map { karaoke in
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
    let toggle: () -> Void
    let seek: (TimeInterval) -> Void
    @State private var dragging: Double?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Icon(playhead.isPlaying ? "player-pause-filled" : "player-play-filled", size: 15)
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Palette.orange, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(Pressable())
            .keyboardShortcut(.space, modifiers: [])
            .help(playhead.isPlaying ? "Pause" : "Play")
            Text(MeetingPresentation.timestamp(shown)).font(Typo.caption).monospacedDigit().foregroundStyle(Palette.secondary)
                .frame(minWidth: 44, alignment: .trailing)
            track
            Text(MeetingPresentation.timestamp(playhead.duration)).font(Typo.caption).monospacedDigit().foregroundStyle(Palette.muted)
                .frame(minWidth: 44, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
        .background(Palette.card, in: Capsule())
        .shadow(color: Palette.shadow, radius: 12, y: 3)
    }

    private var shown: TimeInterval { dragging.map { $0 * playhead.duration } ?? playhead.time }

    private var fraction: Double {
        guard playhead.duration > 0 else { return 0 }
        return dragging ?? min(1, max(0, playhead.time / playhead.duration))
    }

    private var track: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.field).frame(height: hovering || dragging != nil ? 6 : 4)
                Capsule().fill(Palette.orange).frame(width: max(0, width * fraction), height: hovering || dragging != nil ? 6 : 4)
                Circle().fill(Palette.orange).frame(width: 12, height: 12)
                    .offset(x: width * fraction - 6)
                    .opacity(hovering || dragging != nil ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragging = min(1, max(0, $0.location.x / max(1, width))) }
                .onEnded { _ in
                    if let dragging { seek(dragging * playhead.duration) }
                    dragging = nil
                })
            .onHover { hovering = $0 }
            .motion(Motion.touch, value: hovering)
        }
        .frame(height: 24)
        .disabled(playhead.duration <= 0)
    }
}
