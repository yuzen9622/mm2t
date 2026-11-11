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
}

/// A private Core Audio process tap, wrapped in a private aggregate device so it can be read with
/// an ordinary IOProc.
final class ProcessTap {
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private(set) var scope: TapScope
    var processes: [AudioObjectID] { scope.processes }

    init(scope: TapScope) throws {
        self.scope = scope
        let description = Self.description(scope)
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create process tap")
        tapID = tap
        do {
            let tapUID = try CoreAudioProperty.string(tap, kAudioTapPropertyUID)
            // Tap-only aggregate: no output sub-device, so plugging in headphones or changing the
            // default output does not invalidate it; the tap follows the processes, not a device.
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
        var description: CATapDescription = Self.description(scope)
        try withUnsafeMutablePointer(to: &description) { pointer in
            try check(AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), pointer),
                      "update process tap")
        }
        self.scope = scope
    }

    private static func description(_ scope: TapScope) -> CATapDescription {
        let description: CATapDescription = switch scope {
        case .only(let processes): CATapDescription(monoMixdownOfProcesses: processes)
        case .allExcept(let processes): CATapDescription(monoGlobalTapButExcludeProcesses: processes)
        }
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
