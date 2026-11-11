import Foundation

/// Where to cut a recording into pieces without cutting through a word.
public enum QuietCut {
    /// The middle of the quietest stretch of `window` frames, counting both tracks, as an index
    /// into the samples. The tracks cover the same span; the shorter one decides how far to look.
    public static func index(mic: [Int16], remote: [Int16], window: Int) -> Int {
        let count = min(mic.count, remote.count)
        guard window > 0, count > window else { return count }
        var energy = 0.0
        func square(_ i: Int) -> Double {
            let a = Double(mic[i]), b = Double(remote[i])
            return a * a + b * b
        }
        for i in 0..<window { energy += square(i) }
        var best = energy, bestStart = 0
        for start in 1...(count - window) {
            energy += square(start + window - 1) - square(start - 1)
            if energy < best {
                best = energy
                bestStart = start
            }
        }
        return bestStart + window / 2
    }

    /// Whether a stretch holds nothing worth sending to speech recognition: a track nobody played
    /// into is exact zeros, and a muted one is close to it.
    public static func isSilent(_ samples: [Int16]) -> Bool {
        guard !samples.isEmpty else { return true }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot() < 33  // -60 dBFS
    }
}
