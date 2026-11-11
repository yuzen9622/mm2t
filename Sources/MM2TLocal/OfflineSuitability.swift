import Foundation

/// The facts about this Mac that decide whether the on-device models run well on it.
public struct MachineProfile: Equatable, Sendable {
    public let isAppleSilicon: Bool
    public let memoryBytes: UInt64

    public init(isAppleSilicon: Bool, memoryBytes: UInt64) {
        self.isAppleSilicon = isAppleSilicon
        self.memoryBytes = memoryBytes
    }

    public static var current: MachineProfile {
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // Reports 1 on Apple Silicon even when this process runs under Rosetta.
        let found = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0
        return MachineProfile(isAppleSilicon: found && arm64 == 1, memoryBytes: ProcessInfo.processInfo.physicalMemory)
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

    /// Measured on an M4 with 32 GB: Breeze-ASR-25 at 4 bits peaks near 1.2 GB resident while
    /// transcribing, so 8 GB is enough. The 9B LLM peaks near 7 GB, which a 16 GB Mac absorbs beside
    /// the system and an 8 GB one answers by swapping.
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
