import AppKit
import SwiftUI

/// An icon from the bundled set (Tabler, MIT), drawn in the current foreground color.
struct Icon: View {
    let name: String
    var size: CGFloat = 18

    init(_ name: String, size: CGFloat = 18) {
        self.name = name
        self.size = size
    }

    var body: some View {
        if let image = Self.image(name) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor private static func image(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"), let image = NSImage(contentsOf: url) else {
            assertionFailure("missing icon \(name)")
            return nil
        }
        image.isTemplate = true
        cache[name] = image
        return image
    }
}
