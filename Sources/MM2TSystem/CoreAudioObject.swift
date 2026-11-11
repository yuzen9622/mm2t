import CoreAudio
import Foundation

/// A failed Core Audio call, with the operation named so logs and error UI say what broke.
public struct CoreAudioError: Error, CustomStringConvertible, Equatable {
    public let operation: String
    public let status: OSStatus
    public var description: String { "\(operation) failed (OSStatus \(status), '\(fourCC(status))')" }
}

func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(operation: operation(), status: status) }
}

private func fourCC(_ status: OSStatus) -> String {
    let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian, Array.init)
    return bytes.allSatisfy { (32...126).contains($0) } ? String(decoding: bytes, as: UTF8.self) : "\(status)"
}

extension AudioObjectPropertyAddress {
    init(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        self.init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

let systemObject = AudioObjectID(kAudioObjectSystemObject)

enum CoreAudioProperty {
    static func scalar<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                           as type: T.Type = T.self) throws -> T {
        var address = AudioObjectPropertyAddress(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, value), "get '\(selectorName(selector))' on \(object)")
        return value.pointee
    }

    static func array<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                          of type: T.Type = T.self) throws -> [T] {
        var address = AudioObjectPropertyAddress(selector, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "size of '\(selectorName(selector))'")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer), "get '\(selectorName(selector))'")
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "get '\(selectorName(selector))' on \(object)")
        guard let value else { throw CoreAudioError(operation: "'\(selectorName(selector))' was null", status: -1) }
        return value.takeRetainedValue() as String
    }

    static func selectorName(_ selector: AudioObjectPropertySelector) -> String {
        fourCC(OSStatus(bitPattern: selector))
    }
}

enum HostTime {
    static func seconds(_ hostTime: UInt64) -> Double {
        Double(AudioConvertHostTimeToNanos(hostTime)) / 1_000_000_000
    }

    static var now: Double { seconds(AudioGetCurrentHostTime()) }
}

/// Keeps a property listener registered until `remove()`; listener blocks run on `queue`.
final class PropertyListener: @unchecked Sendable {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var isRegistered = false

    init(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, queue: DispatchQueue,
         _ handler: @escaping @Sendable () -> Void) throws {
        self.object = object
        self.address = AudioObjectPropertyAddress(selector)
        self.queue = queue
        self.block = { _, _ in handler() }
        try check(AudioObjectAddPropertyListenerBlock(object, &address, queue, block), "listen to '\(CoreAudioProperty.selectorName(selector))'")
        isRegistered = true
    }

    func remove() {
        guard isRegistered else { return }
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        isRegistered = false
    }

    deinit { remove() }
}
