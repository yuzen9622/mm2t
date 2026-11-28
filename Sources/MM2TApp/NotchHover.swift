/// Accepting the recording prompt consumes the current hover. A fresh entry opens the controls.
public enum NotchHover: Sendable {
    case outside, inside, waitingForExit

    public mutating func pointerChanged(inside: Bool) {
        if !inside { self = .outside }
        else if self == .outside { self = .inside }
    }

    public mutating func recordingBegan() {
        if self == .inside { self = .waitingForExit }
    }
}
