import CoreAudio
import Foundation

/// What a tap listens to.
enum TapScope: Equatable {
    /// Only these processes, so other apps' sound never reaches the remote track.
    case only([AudioObjectID])
    /// Everything the Mac plays except these processes; used when no meeting app is the target.
    case allExcept([AudioObjectID])

    var processes: [AudioObjectID] {
        switch self {
        case .only(let processes), .allExcept(let processes): processes
        }
    }

    /// Capture original producers once. FineTune re-renders their audio after processing; a
    /// global tap otherwise records both the original and its delayed, re-rendered copy.
    /// Keep idle relay processes excluded too, since they can start output without a list change.
    static func recording(targetBundleID: String?, ownBundleID: String?, processes: [AudioProcess]) -> TapScope {
        if let targetBundleID {
            return .only(processes.filter { $0.ownerBundleID == targetBundleID }.map(\.objectID).sorted())
        }
        return .allExcept(processes.filter { process in
            (ownBundleID != nil && process.ownerBundleID == ownBundleID)
                || isAudioRelay(process.ownerBundleID) || isAudioRelay(process.identity.bundleID)
        }.map(\.objectID).sorted())
    }

    static func isAudioRelay(_ bundleID: String?) -> Bool {
        bundleID == "com.finetuneapp.FineTune"
    }
}

/// A private Core Audio process tap, wrapped in a private aggregate device so it can be read with
/// an ordinary IOProc.
final class ProcessTap {
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private(set) var scope: TapScope
    private let outputUID: String
    private let uuid = UUID()
    var processes: [AudioObjectID] { scope.processes }

    init(scope: TapScope, outputDevice: AudioObjectID) throws {
        self.scope = scope
        outputUID = try CoreAudioProperty.string(outputDevice, kAudioDevicePropertyDeviceUID)
        let description = Self.description(scope, outputUID: outputUID, uuid: uuid)
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create process tap")
        tapID = tap
        do {
            let tapUID = try CoreAudioProperty.string(tap, kAudioTapPropertyUID)
            // No output sub-device: this aggregate only captures. The recorder rebuilds the tap
            // when the selected output changes, so we never mix copies from multiple routes.
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "mm2t remote tap",
                kAudioAggregateDeviceUIDKey: "mm2t.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
            ]
            var aggregate = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "create aggregate device for tap")
            aggregateID = aggregate
        } catch {
            AudioHardwareDestroyProcessTap(tap)
            throw error
        }
    }

    /// Retargets the live tap when the app spawns or loses audio helpers, without recreating it.
    func setScope(_ scope: TapScope) throws {
        guard scope != self.scope else { return }
        var address = AudioObjectPropertyAddress(kAudioTapPropertyDescription)
        var description: CATapDescription = Self.description(scope, outputUID: outputUID, uuid: uuid)
        try withUnsafeMutablePointer(to: &description) { pointer in
            try check(AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), pointer),
                      "update process tap")
        }
        self.scope = scope
    }

    static func description(_ scope: TapScope, outputUID: String, uuid: UUID) -> CATapDescription {
        let description: CATapDescription = switch scope {
        case .only(let processes): CATapDescription(processes: processes, deviceUID: outputUID, stream: 0)
        case .allExcept(let processes): CATapDescription(excludingProcesses: processes, deviceUID: outputUID, stream: 0)
        }
        // Capture one output stream. CaptureRing downmixes its channels to mono, after routing.
        // A global mix can include delayed copies from other hardware or virtual output routes.
        description.uuid = uuid
        description.name = "mm2t remote"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    func destroy() {
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { destroy() }
}
