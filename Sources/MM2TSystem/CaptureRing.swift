import CoreAudio
import os

/// Single-producer, single-consumer hand-off from a Core Audio IO thread to the writer.
/// The IO side never allocates; it downmixes into preallocated slots and only takes an unfair
/// lock to publish an index, which the writer holds for a few instructions at a time.
final class CaptureRing: @unchecked Sendable {
    struct Chunk {
        var hostTime: UInt64 = 0
        var sampleRate: Double = 0
        /// Frames between `hostTime` and this chunk's first frame, when one IO buffer spans slots.
        var frameOffset = 0
        var frames = 0
    }

    private struct Indices {
        var written = 0
        var read = 0
        var droppedFrames = 0
        var lastHostTime: UInt64 = 0
    }

    let slotFrames: Int
    let slotCount: Int
    private let samples: UnsafeMutablePointer<Float>
    private let chunks: UnsafeMutablePointer<Chunk>
    private let indices = OSAllocatedUnfairLock(initialState: Indices())

    init(slotFrames: Int = 4096, slotCount: Int = 512) {
        self.slotFrames = slotFrames
        self.slotCount = slotCount
        samples = .allocate(capacity: slotFrames * slotCount)
        samples.initialize(repeating: 0, count: slotFrames * slotCount)
        chunks = .allocate(capacity: slotCount)
        chunks.initialize(repeating: Chunk(), count: slotCount)
    }

    deinit {
        samples.deallocate()
        chunks.deallocate()
    }

    /// Called on the IO thread. Buffers hold Float32, interleaved or planar; all channels are averaged.
    func write(_ buffers: UnsafePointer<AudioBufferList>, hostTime: UInt64, sampleRate: Double) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers))
        guard let first = list.first, first.mNumberChannels > 0 else { return }
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / Int(first.mNumberChannels)
        var offset = 0
        while offset < frames {
            let count = min(slotFrames, frames - offset)
            let slot: Int? = indices.withLock { state in
                state.lastHostTime = hostTime
                guard state.written - state.read < slotCount else {
                    state.droppedFrames += count
                    return nil
                }
                return state.written % slotCount
            }
            guard let slot else { return }
            let destination = samples + slot * slotFrames
            downmix(list, frames: offset ..< offset + count, into: destination)
            chunks[slot] = Chunk(hostTime: hostTime, sampleRate: sampleRate, frameOffset: offset, frames: count)
            indices.withLock { $0.written += 1 }
            offset += count
        }
    }

    private func downmix(_ list: UnsafeMutableAudioBufferListPointer, frames: Range<Int>, into destination: UnsafeMutablePointer<Float>) {
        destination.update(repeating: 0, count: frames.count)
        var channelCount = 0
        for buffer in list {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size >= frames.upperBound * channels else { continue }
            for frame in frames {
                var sum: Float = 0
                for channel in 0 ..< channels { sum += data[frame * channels + channel] }
                destination[frame - frames.lowerBound] += sum
            }
            channelCount += channels
        }
        guard channelCount > 1 else { return }
        let scale = 1 / Float(channelCount)
        for i in 0 ..< frames.count { destination[i] *= scale }
    }

    /// Called on the writer. Hands over every chunk published so far, in order.
    func drain(_ body: (Chunk, UnsafeBufferPointer<Float>) -> Void) {
        let (start, end) = indices.withLock { ($0.read, $0.written) }
        for index in start ..< end {
            let slot = index % slotCount
            let chunk = chunks[slot]
            body(chunk, UnsafeBufferPointer(start: samples + slot * slotFrames, count: chunk.frames))
        }
        indices.withLock { $0.read = end }
    }

    /// Frames lost because the writer fell behind; also clears the count.
    func takeDroppedFrames() -> Int {
        indices.withLock { state in
            defer { state.droppedFrames = 0 }
            return state.droppedFrames
        }
    }

    /// Host time of the most recent IO callback, or 0 if none yet.
    var lastHostTime: UInt64 { indices.withLock { $0.lastHostTime } }
}
