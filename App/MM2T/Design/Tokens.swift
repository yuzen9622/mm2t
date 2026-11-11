import AppKit
import SwiftUI

/// Every color the app draws with. Two values each: light, dark.
enum Palette {
    static let window = dynamic(0xF6F5F1, 0x1B1B1D)
    static let sidebar = dynamic(0xEEEDE8, 0x151516)
    static let card = dynamic(0xFFFFFF, 0x262628)
    static let field = dynamic(0xEDECE7, 0x303033)
    static let border = Color(nsColor: NSColor(name: nil) { $0.isDark ? .white.withAlphaComponent(0.10) : .black.withAlphaComponent(0.08) })
    static let hover = Color(nsColor: NSColor(name: nil) { $0.isDark ? .white.withAlphaComponent(0.07) : .black.withAlphaComponent(0.05) })
    static let text = dynamic(0x1C1C1E, 0xF5F5F7)
    static let secondary = dynamic(0x6C6C70, 0xA1A1A6)
    static let muted = dynamic(0xA3A3A8, 0x6E6E73)
    static let orange = Color(hex: 0xF0700F)
    static let orangeSoft = Color(hex: 0xF0700F).opacity(0.14)
    static let danger = dynamic(0xD63B30, 0xFF6961)
    static let success = dynamic(0x2E9E4F, 0x30D158)

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { NSColor(hex: $0.isDark ? dark : light) })
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

enum Radius {
    static let card: CGFloat = 14
    static let control: CGFloat = 10
}

/// One type scale for the whole app, all in the rounded design.
enum Typo {
    static let title = Font.system(size: 20, weight: .semibold, design: .rounded)
    static let heading = Font.system(size: 15, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 14, weight: .regular, design: .rounded)
    static let bodyStrong = Font.system(size: 14, weight: .medium, design: .rounded)
    static let caption = Font.system(size: 12, weight: .regular, design: .rounded)
    static let captionStrong = Font.system(size: 12, weight: .medium, design: .rounded)
}

/// The app's motion vocabulary. Each case is one kind of change, so the same change always moves
/// the same way.
enum Motion {
    /// A control answering the pointer: hover tint, press.
    static let touch = Animation.spring(response: 0.20, dampingFraction: 0.72)
    /// A selection moving between options: sidebar, segmented control, avatar stack.
    static let select = Animation.spring(response: 0.34, dampingFraction: 0.80)
    /// One screen replacing another: section change, list to detail.
    static let page = Animation.spring(response: 0.44, dampingFraction: 0.88)
    /// Content appearing or leaving in place: banners, tooltips, capsule states.
    static let reveal = Animation.spring(response: 0.30, dampingFraction: 0.84)
}

extension View {
    /// Animates with `animation` unless the user asked macOS to reduce motion, in which case the
    /// change is a short fade with no movement.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content.animation(reduce ? .easeOut(duration: 0.12) : animation, value: value)
    }
}

/// Movement for a screen or element entering; plain fade under Reduce Motion.
struct Entrance: ViewModifier {
    let edge: Edge
    let distance: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content.transition(reduce ? .opacity : .asymmetric(
            insertion: .offset(x: edge == .trailing ? distance : edge == .leading ? -distance : 0,
                               y: edge == .bottom ? distance : edge == .top ? -distance : 0).combined(with: .opacity),
            removal: .opacity))
    }
}

extension View {
    func entrance(from edge: Edge = .bottom, distance: CGFloat = 12) -> some View {
        modifier(Entrance(edge: edge, distance: distance))
    }
}
