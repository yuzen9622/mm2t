/// The modifier keys a shortcut can use.
public struct HotkeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = HotkeyModifiers(rawValue: 1 << 0)
    public static let option = HotkeyModifiers(rawValue: 1 << 1)
    public static let shift = HotkeyModifiers(rawValue: 1 << 2)
    public static let command = HotkeyModifiers(rawValue: 1 << 3)
    /// Fn, the Globe key on newer keyboards.
    public static let function = HotkeyModifiers(rawValue: 1 << 4)

    /// The ones that turn a key press into a command rather than typing.
    static let commanding: HotkeyModifiers = [.control, .option, .command]

    var count: Int { rawValue.nonzeroBitCount }

    /// macOS's own order, ⌃⌥⇧⌘, with Fn after them.
    public var symbols: String {
        [(Self.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"), (.function, "Fn")]
            .filter { contains($0.0) }.map(\.1).joined()
    }
}

/// The global shortcut that starts and stops a recording: either modifiers alone (⌘Fn), which fire
/// when they are let go, or modifiers with one key (⌃⌥R), which fire when the key goes down.
public struct Hotkey: Codable, Hashable, Sendable {
    public var modifiers: HotkeyModifiers
    /// The key's virtual key code (`kVK_*`); nil for a chord of modifiers alone.
    public var keyCode: UInt16?
    /// What the key read as when it was recorded. The code names a position on the keyboard, and
    /// which character sits there depends on the layout.
    public var keyLabel: String?

    public init(modifiers: HotkeyModifiers, keyCode: UInt16? = nil, keyLabel: String? = nil) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.keyLabel = keyLabel
    }

    /// The default: Command with Fn (Globe), pressed together and let go.
    public static let commandFn = Hotkey(modifiers: [.command, .function])

    public var usesFunctionKey: Bool { modifiers.contains(.function) }

    public var symbols: String { modifiers.symbols + (keyLabel ?? "") }
}

/// Decides when the shortcut fires, from the modifier changes and key presses the system reports.
///
/// A chord of modifiers alone fires once, on release, only if exactly its modifiers went down and
/// nothing else happened while any were held: no other key (⌘Fn← is a shortcut of its own) and no
/// further modifier. With no hold-to-stop and no undo, this strictness is the only guard against
/// stopping a recording by accident.
public struct HotkeyDetector: Sendable {
    public let hotkey: Hotkey
    private var held: HotkeyModifiers
    /// Exactly the chord's modifiers have been down together during this press.
    private var armed = false
    /// Something else happened during this press, or the press began before this detector saw it,
    /// so nothing fires, chord or key, until every modifier is up.
    private var spoiled: Bool

    /// `held` is what is down as the detector starts watching. A press already in progress then is
    /// ignored to its end: it is the one that was just typed into the shortcut field, or the one
    /// under way when the shortcut changed, and it must not start or stop a recording.
    public init(hotkey: Hotkey, held: HotkeyModifiers = []) {
        self.hotkey = hotkey
        self.held = held
        spoiled = !held.isEmpty
    }

    /// The modifiers now held, after a modifier key went down or up. Returns whether the shortcut fired.
    public mutating func modifiersChanged(_ now: HotkeyModifiers) -> Bool {
        held = now
        if now.isEmpty {
            defer { armed = false; spoiled = false }
            return hotkey.keyCode == nil && armed && !spoiled
        }
        guard hotkey.keyCode == nil else { return false }
        if !now.subtracting(hotkey.modifiers).isEmpty { spoiled = true }
        if now == hotkey.modifiers, !spoiled { armed = true }
        return false
    }

    /// A key that is not a modifier went down while `modifiers` were held. Returns whether the shortcut fired.
    public mutating func keyDown(_ keyCode: UInt16, modifiers: HotkeyModifiers, isRepeat: Bool) -> Bool {
        guard let key = hotkey.keyCode else {
            if !held.isEmpty { spoiled = true }
            return false
        }
        // macOS sets the Fn flag on arrow and function keys by itself, so on a key press it does
        // not say the user held Fn; shortcuts with a key are matched without it.
        return !spoiled && !isRepeat && keyCode == key
            && modifiers.subtracting(.function) == hotkey.modifiers.subtracting(.function)
    }
}

/// Turns what the user presses in the shortcut field into a `Hotkey`.
///
/// Modifiers let go with no key between them become a chord, if there are at least two: a single
/// modifier tapped alone happens too often in ordinary typing. A key becomes a shortcut only with
/// ⌃, ⌥ or ⌘, since with no modifier or only ⇧ it types.
public struct HotkeyRecorder: Sendable {
    private var peak: HotkeyModifiers = []
    private var spoiled = false

    public init() {}

    public mutating func modifiersChanged(_ now: HotkeyModifiers) -> Hotkey? {
        peak.formUnion(now)
        guard now.isEmpty else { return nil }
        defer { peak = []; spoiled = false }
        return !spoiled && peak.count >= 2 ? Hotkey(modifiers: peak) : nil
    }

    /// `label` is what the key reads as in the current layout, shown in the field.
    public mutating func keyDown(_ keyCode: UInt16, modifiers: HotkeyModifiers, label: String) -> Hotkey? {
        let modifiers = modifiers.subtracting(.function)
        guard !modifiers.isDisjoint(with: HotkeyModifiers.commanding) else {
            spoiled = true
            return nil
        }
        peak = []
        spoiled = true
        return Hotkey(modifiers: modifiers, keyCode: keyCode, keyLabel: label)
    }
}
