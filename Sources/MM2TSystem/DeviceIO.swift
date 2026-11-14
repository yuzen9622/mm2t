import CoreAudio
import Foundation

/// Runs an input IOProc on one Core Audio device and feeds its audio into a ring.
final class DeviceIO {
    let device: AudioObjectID
    private var procID: AudioDeviceIOProcID?
    private var isRunning = false

    init(device: AudioObjectID, ring: CaptureRing) throws {
        self.device = device
        let streams = try CoreAudioProperty.array(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, of: AudioObjectID.self)
        guard let stream = streams.first else {
            throw CoreAudioError(operation: "device \(device) has no input stream", status: OSStatus(kAudioHardwareBadDeviceError))
        }
        let format = try CoreAudioProperty.scalar(stream, kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription.self)
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32
        else { throw CoreAudioError(operation: "device \(device) input is not Float32", status: OSStatus(kAudioDeviceUnsupportedFormatError)) }
        let sampleRate = format.mSampleRate
        var procID: AudioDeviceIOProcID?
        // The block runs on the device's real-time IO thread: no allocation, no awaiting, no locks
        // beyond the ring's index lock.
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, input, inputTime, _, _ in
            ring.write(input, hostTime: inputTime.pointee.mHostTime, sampleRate: sampleRate)
        }, "create IOProc on device \(device)")
        self.procID = procID
    }

    func start() throws {
        guard let procID, !isRunning else { return }
        try check(AudioDeviceStart(device, procID), "start device \(device)")
        isRunning = true
    }

    func stop() {
        guard let procID else { return }
        if isRunning { AudioDeviceStop(device, procID) }
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
        isRunning = false
    }

    deinit { stop() }
}

enum AudioDevices {
    static func defaultOutput() throws -> AudioObjectID {
        let device = try CoreAudioProperty.scalar(systemObject, kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)
        guard device != kAudioObjectUnknown else {
            throw CoreAudioError(operation: "find default output device", status: OSStatus(kAudioHardwareBadDeviceError))
        }
        return device
    }

    static func defaultInput() throws -> AudioObjectID {
        let device = try CoreAudioProperty.scalar(systemObject, kAudioHardwarePropertyDefaultInputDevice, as: AudioObjectID.self)
        guard device != kAudioObjectUnknown else { throw RecorderError.noInputDevice }
        return device
    }

    static func name(_ device: AudioObjectID) -> String {
        (try? CoreAudioProperty.string(device, kAudioObjectPropertyName)) ?? "device \(device)"
    }
}
