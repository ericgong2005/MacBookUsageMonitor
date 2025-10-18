import Foundation

public func now() -> UInt32 { UInt32(Date().timeIntervalSinceReferenceDate) }

public extension Data {
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var v = value
        withUnsafeBytes(of: &v) { append($0) }
    }

    func readInteger<T: FixedWidthInteger>(at offset: Int, as: T.Type = T.self) -> T {
        precondition(offset + MemoryLayout<T>.size <= count, "Out of bounds read")
        var value = T.zero
        withUnsafeMutableBytes(of: &value) { dst in
            copyBytes(to: dst, from: offset..<(offset + MemoryLayout<T>.size))
        }
        return value
    }
}