import Foundation
import Sparkle
import SwiftUI

/// Sparkle reads SUFeedURL and SUPublicEDKey from Info.plist and checks once a day after the user agrees.
@MainActor
enum Updates {
    static let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    /// Builds from source keep the placeholder key, and Sparkle would greet them with an error alert,
    /// so they run without updates.
    static let isConfigured: Bool = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let data = Data(base64Encoded: key) else { return false }
        return data.count == 32
    }()

    static func start() {
        if isConfigured { controller.startUpdater() }
    }
}

struct CheckForUpdatesButton: View {
    @State private var canCheck = false

    var body: some View {
        if Updates.isConfigured {
            Button("Check for Updates…") { Updates.controller.checkForUpdates(nil) }
                .disabled(!canCheck)
                .onReceive(Updates.controller.updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
        }
    }
}
