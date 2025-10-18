import Foundation
import Darwin

public func now() -> UInt32 { UInt32(Date().timeIntervalSinceReferenceDate) }
public func NowString() -> String { ISO8601DateFormatter().string(from: Date()) }

public extension Data {
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var v = value
        Swift.withUnsafeBytes(of: &v) { rawBuf in
            self.append(contentsOf: rawBuf)
        }
    }

    func readInteger<T: FixedWidthInteger>(at offset: Int, as: T.Type) -> T {
        precondition(offset + MemoryLayout<T>.size <= count, "Out of bounds read")
        return self.withUnsafeBytes { rawBuf in
            rawBuf.load(fromByteOffset: offset, as: T.self)
        }
    }
}

public func AtomicAppend(_ data: Data, to path: String) {
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
    guard fd >= 0 else { perror("open"); return }
    defer { close(fd) }

    data.withUnsafeBytes { buf in
        var base = buf.bindMemory(to: UInt8.self).baseAddress!
        var remaining = buf.count
        while remaining > 0 {
            let n = write(fd, base, remaining)
            if n < 0 { perror("write"); return }
            remaining -= n
            base += n
        }
    }

    fsync(fd)
}

public func AtomicTimeUpdate(at url: URL) -> Bool {
    let dirURL = url.deletingLastPathComponent()
    let destPath = url.path

    let templatePath = dirURL.appendingPathComponent("." + url.lastPathComponent + ".tmp.XXXXXX").path
    var cTemplate = Array(templatePath.utf8CString)
    let fd = mkstemp(&cTemplate)
    if fd == -1 { return false }

    let tempPath: String = cTemplate.withUnsafeBufferPointer { ptr in
        let u8 = ptr.map { UInt8(bitPattern: $0) }
        let end = u8.firstIndex(of: 0) ?? u8.count
        return String(decoding: u8[..<end], as: UTF8.self)
    }

    var data = Data()
    data.appendInteger(now())

    let ok = data.withUnsafeBytes { buf -> Bool in
        let n = write(fd, buf.baseAddress, buf.count)
        return n == buf.count
    }
    close(fd)

    guard ok else {
        _ = unlink(tempPath)
        return false
    }

    if rename(tempPath, destPath) != 0 {
        _ = unlink(tempPath)
        return false
    }
    return true
}