import CoreAudio
import Foundation

/// A private Core Audio process tap on a set of process objects, wrapped in a private aggregate
/// device so it can be read with an ordinary IOProc. Taps only the listed processes, so other
/// apps' sound never reaches the remote track.
@available(macOS 14.2, *)
final class ProcessTap {
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private(set) var processes: [AudioObjectID]

    init(processes: [AudioObjectID]) throws {
        self.processes = processes
        let description = Self.description(processes)
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
    func setProcesses(_ processes: [AudioObjectID]) throws {
        guard processes != self.processes else { return }
        var address = AudioObjectPropertyAddress(kAudioTapPropertyDescription)
        var description: CATapDescription = Self.description(processes)
        try withUnsafeMutablePointer(to: &description) { pointer in
            try check(AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), pointer),
                      "update process tap")
        }
        self.processes = processes
    }

    private static func description(_ processes: [AudioObjectID]) -> CATapDescription {
        let description = CATapDescription(monoMixdownOfProcesses: processes)
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
