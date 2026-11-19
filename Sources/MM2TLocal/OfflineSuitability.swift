import Foundation

/// The facts about this Mac that decide whether the on-device models run well on it.
public struct MachineProfile: Equatable, Sendable {
    public let isAppleSilicon: Bool
    public let isTranslated: Bool
    public let memoryBytes: UInt64

    public init(isAppleSilicon: Bool, memoryBytes: UInt64, isTranslated: Bool = false) {
        self.isAppleSilicon = isAppleSilicon
        self.isTranslated = isTranslated
        self.memoryBytes = memoryBytes
    }

    public static var current: MachineProfile {
        #if arch(arm64)
        return MachineProfile(isAppleSilicon: true, memoryBytes: ProcessInfo.processInfo.physicalMemory)
        #else
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
        return MachineProfile(isAppleSilicon: rosetta, memoryBytes: ProcessInfo.processInfo.physicalMemory, isTranslated: rosetta)
        #endif
    }
}

/// Whether one offline option is a good idea on this Mac (spec story 36). Advice only: the user can
/// still turn the option on.
public enum OfflineFit: Equatable, Sendable {
    case suited
    case unsuited(Reason)

    public enum Reason: Equatable, Sendable {
        /// The CoreML speech model needs the Neural Engine and the LLM needs unified memory on the GPU.
        case intelProcessor
        case memory(minimumGB: Int)
    }
}

public struct OfflineSuitability: Equatable, Sendable {
    public let transcription: OfflineFit
    public let llm: OfflineFit

    public init(_ machine: MachineProfile) {
        guard machine.isAppleSilicon else {
            transcription = .unsuited(.intelProcessor)
            llm = .unsuited(.intelProcessor)
            return
        }
        let gigabytes = Double(machine.memoryBytes) / 1_073_741_824
        transcription = gigabytes >= 7.5 ? .suited : .unsuited(.memory(minimumGB: 8))
        llm = gigabytes >= 15.5 ? .suited : .unsuited(.memory(minimumGB: 16))
    }
}
