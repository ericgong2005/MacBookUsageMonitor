// Sources/UsageMonitor/main.swift
import Foundation
import IOKit.ps
import IOKit
import os.log

// MARK: - Byte helpers (native endianness, no padding)
extension Data {
    /// Append a fixed-width integer in native endianness.
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var v = value // must be var to take an address
        withUnsafeBytes(of: &v) { append($0) }
    }

    /// Read a fixed-width integer from `offset` in native endianness (safe for unaligned offsets).
    func readInteger<T: FixedWidthInteger>(at offset: Int, as: T.Type = T.self) -> T {
        precondition(offset + MemoryLayout<T>.size <= count, "Out of bounds read")
        var value = T.zero
        withUnsafeMutableBytes(of: &value) { dst in
            copyBytes(to: dst, from: offset..<(offset + MemoryLayout<T>.size))
        }
        return value
    }
}

// MARK: - Fixed-size record
struct Record: Equatable, CustomStringConvertible {
    var id: UInt32          // 4 bytes
    var status: UInt8       // 1
    var quality: UInt8      // 1
    var version: UInt16     // 2
    var counter: UInt32     // 4
    var checksum: UInt64    // 8
    // total = 20 bytes (no padding in file; we pack fields ourselves)

    static let byteSize =
        MemoryLayout<UInt32>.size +  // id
        MemoryLayout<UInt8>.size  +  // status
        MemoryLayout<UInt8>.size  +  // quality
        MemoryLayout<UInt16>.size +  // version
        MemoryLayout<UInt32>.size +  // counter
        MemoryLayout<UInt64>.size    // checksum

    // Encode into a Data buffer (native endianness).
    func encode(into data: inout Data) {
        data.appendInteger(id)
        data.appendInteger(status)
        data.appendInteger(quality)
        data.appendInteger(version)
        data.appendInteger(counter)
        data.appendInteger(checksum)
    }

    // Decode from Data at a byte offset.
    static func decode(from data: Data, at offset: Int) -> Record? {
        guard offset + byteSize <= data.count else { return nil }
        var i = offset
        let id: UInt32      = data.readInteger(at: i);                  i += 4
        let status: UInt8   = data.readInteger(at: i);                  i += 1
        let quality: UInt8  = data.readInteger(at: i);                  i += 1
        let version: UInt16 = data.readInteger(at: i);                  i += 2
        let counter: UInt32 = data.readInteger(at: i);                  i += 4
        let checksum: UInt64 = data.readInteger(at: i);                 i += 8
        return Record(id: id, status: status, quality: quality,
                      version: version, counter: counter, checksum: checksum)
    }

    var description: String {
        "Record(id:\(id), status:\(status), quality:\(quality), version:\(version), counter:\(counter), checksum:\(checksum))"
    }
}

// MARK: - File IO
enum RecordFileError: Error {
    case corruptFile
    case indexOutOfBounds
}

func save(_ records: [Record], to url: URL) throws {
    var blob = Data(capacity: records.count * Record.byteSize)
    for r in records { r.encode(into: &blob) }
    try blob.write(to: url, options: .atomic)
}

func loadAll(from url: URL) throws -> [Record] {
    let data = try Data(contentsOf: url)
    guard data.count % Record.byteSize == 0 else { throw RecordFileError.corruptFile }
    var out: [Record] = []
    out.reserveCapacity(data.count / Record.byteSize)
    var offset = 0
    while offset < data.count {
        guard let rec = Record.decode(from: data, at: offset) else { throw RecordFileError.corruptFile }
        out.append(rec)
        offset += Record.byteSize
    }
    return out
}

/// Random-access: extract a single record at `index` without loading the whole file.
func loadRecord(at index: Int, from url: URL) throws -> Record {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    // Verify file length aligns to record size (optional but safer)
    let size = try handle.seekToEnd()
    guard size % UInt64(Record.byteSize) == 0 else { throw RecordFileError.corruptFile }

    let count = Int(size) / Record.byteSize
    guard index >= 0 && index < count else { throw RecordFileError.indexOutOfBounds }

    let offset = UInt64(index * Record.byteSize)
    try handle.seek(toOffset: offset)
    let chunk = try handle.read(upToCount: Record.byteSize) ?? Data()
    guard chunk.count == Record.byteSize, let rec = Record.decode(from: chunk, at: 0) else {
        throw RecordFileError.corruptFile
    }
    return rec
}

// MARK: - Example usage
do {
    let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("records.bin")

    let records: [Record] = [
        .init(id: 1, status: 3, quality: 90, version: 1, counter: 10, checksum: 0xDEADBEEF00112233),
        .init(id: 2, status: 2, quality: 80, version: 1, counter: 20, checksum: 0xABCDEF1234567890),
        .init(id: 3, status: 1, quality: 70, version: 2, counter: 30, checksum: 0x0102030405060708),
    ]

    try save(records, to: tmpURL)

    // Load a single entry by index (e.g., the third record)
    let third = try loadRecord(at: 2, from: tmpURL)
    print("Loaded single record:", third)

    // Or load all back
    let roundTrip = try loadAll(from: tmpURL)
    print("Loaded \(roundTrip.count) records")
} catch {
    print("Error:", error)
}


// =======================================
// File definition (and directory) at top
// =======================================
let fm = FileManager.default
let baseDir: URL = {
    let appSup = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return appSup.appendingPathComponent("UsageMonitor", isDirectory: true)
}()
let stateLogURL = baseDir.appendingPathComponent("state_log.csv")

// =======================
// Enums (numeric in CSV)
// =======================
enum ScreenState: Int, CustomStringConvertible {
    case unlocked = 0
    case locked   = 1
    var description: String { String(rawValue) }  
    var label: String { self == .locked ? "Lock" : "Unlock" }
}

enum ChargeState: Int, CustomStringConvertible {
    case battery = 0
    case charger = 1
    var description: String { String(rawValue) }          // prints 0/1 in CSV
    var label: String { self == .charger ? "Charger" : "Battery" }
}

// ==============
// Entry model
// ==============
struct StateEntry {
    let time: Date
    let screen: ScreenState
    let charge: ChargeState
}

// -------------- CSV helpers --------------
let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func csvRow(_ e: StateEntry) -> String {
    "\(iso.string(from: e.time)),\(e.screen),\(e.charge)"
}

func parseCSVRow(_ line: String) -> StateEntry? {
    // Expect: EntryTime,UseState,ChargeState
    let parts = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 3 else { return nil }
    guard let t = iso.date(from: parts[0]),
          let screenRaw = Int(parts[1]),
          let chargeRaw = Int(parts[2]),
          let s = ScreenState(rawValue: screenRaw),
          let c = ChargeState(rawValue: chargeRaw) else { return nil }
    return StateEntry(time: t, screen: s, charge: c)
}

// --------------------- File primitives ---------------------
func ensureFileExistsWithHeader() {
    try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
    if !fm.fileExists(atPath: stateLogURL.path) {
        let header = "EntryTime,UseState,ChargeState\n"
        try? header.data(using: .utf8)!.write(to: stateLogURL, options: .atomic)
    }
}

func readLastEntry(from url: URL) -> StateEntry? {
    guard let data = try? Data(contentsOf: url),
          var text = String(data: data, encoding: .utf8) else { return nil }
    // Trim trailing newlines; split; skip header
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var lines = text.components(separatedBy: .newlines)
    guard lines.count >= 2 else { return nil } // header only or empty
    // walk backward to find the last non-empty, parseable line
    for line in lines.reversed() {
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        if line.hasPrefix("EntryTime") { break } // reached header
        if let e = parseCSVRow(line) { return e }
    }
    return nil
}

func appendEntry(_ e: StateEntry, to url: URL) throws {
    let line = csvRow(e) + "\n"
    let data = line.data(using: .utf8)!
    if fm.fileExists(atPath: url.path) {
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        fh.seekToEndOfFile()              // <- **append** to the end
        fh.write(data)                    // (no rewriting of previous contents)
    } else {
        try data.write(to: url, options: .atomic) // shouldn't happen if ensured above
    }
}

// =======================================
// Boot logic requested in your prompt
// =======================================
ensureFileExistsWithHeader()

if let last = readLastEntry(from: stateLogURL) {
    if last.screen != .locked {
        // Append a copy of last entry, but with .locked
        let patched = StateEntry(time: last.time, screen: .locked, charge: last.charge)
        try? appendEntry(patched, to: stateLogURL)
        // (If you prefer to stamp "now" instead of duplicating time, swap last.time for Date())
    }
}

// =======================
// Demo: normal appending
// =======================
let nowUnlockedOnBattery = StateEntry(time: Date(), screen: .unlocked, charge: .battery)
let nowLockedOnCharger   = StateEntry(time: Date().addingTimeInterval(0.5), screen: .locked, charge: .charger)

try? appendEntry(nowUnlockedOnBattery, to: stateLogURL)
try? appendEntry(nowLockedOnCharger,   to: stateLogURL)

print("Appended 2 demo rows to:", stateLogURL.path)


// MARK: - Paths & Utilities

struct UMPaths {
    let baseDir: URL
    let logsDir: URL
    let batteryCSV: URL
    let stateCSV: URL
    let cyclesCSV: URL
    let keyCountsCurrent: URL

    init() {
        let fm = FileManager.default
        let appSup = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true)
        baseDir = appSup.appendingPathComponent("UsageMonitor", isDirectory: true)
        logsDir = baseDir.appendingPathComponent("logs", isDirectory: true)
        batteryCSV = baseDir.appendingPathComponent("battery_log.csv")
        stateCSV = baseDir.appendingPathComponent("state_log.csv")
        cyclesCSV = baseDir.appendingPathComponent("cycles_health.csv")
        keyCountsCurrent = baseDir.appendingPathComponent("key_counts_current.json")

        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }

    func dailyKeyCountsSnapshotURL(_ date: Date = Date()) -> URL {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return baseDir.appendingPathComponent("key_counts_\(df.string(from: date)).json")
    }
}

let iso8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

// MARK: - Batched File Writer (append-only CSV)

final class BatchFileWriter {
    private let url: URL
    private let header: String?
    private let queue = DispatchQueue(label: "um.filewriter.\(UUID().uuidString)")
    private var buffer = Data()
    private let flushInterval: TimeInterval
    private let maxBufferBytes: Int
    private var timer: DispatchSourceTimer?

    init(url: URL, header: String?, flushInterval: TimeInterval = 5.0, maxBufferBytes: Int = 16 * 1024) {
        self.url = url
        self.header = header
        self.flushInterval = flushInterval
        self.maxBufferBytes = maxBufferBytes
        prepareFileIfNeeded()
        startTimer()
    }

    private func prepareFileIfNeeded() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            if let h = header {
                try? (h + "\n").data(using: .utf8)?.write(to: url, options: .atomic)
            } else {
                try? Data().write(to: url, options: .atomic)
            }
        }
    }

    func appendLine(_ line: String) {
        queue.async {
            if let data = (line + "\n").data(using: .utf8) {
                self.buffer.append(data)
                if self.buffer.count >= self.maxBufferBytes {
                    self.flushSync()
                }
            }
        }
    }

    func flush() {
        queue.async { self.flushSync() }
    }

    private func flushSync() {
        guard buffer.count > 0 else { return }
        do {
            let fh = try FileHandle(forWritingTo: url)
            defer { try? fh.close() }
            try fh.seekToEnd()
            try fh.write(contentsOf: buffer)
            try fh.synchronize()
            buffer.removeAll(keepingCapacity: true)
        } catch {
            os_log("File flush failed: %{public}@", "\(error)")
        }
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        t.setEventHandler { [weak self] in self?.flushSync() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        flush()
    }
}

// MARK: - Battery & Power Reading

struct BatterySnapshot: Equatable {
    let percent: Int
    let chargeState: String // "Charger" | "Battery"
}

struct CycleHealthSnapshot: Equatable {
    let cycleCount: Int?
    let healthPercent: Int?
}

final class PowerMonitor {
    private var powerSourceRunLoop: Unmanaged<CFRunLoopSource>?

    var onBatteryChange: ((BatterySnapshot) -> Void)?
    var onCycleHealthChange: ((CycleHealthSnapshot) -> Void)?

    private var lastBattery: BatterySnapshot?
    private var lastCycleHealth: CycleHealthSnapshot?

    func start() {
        // Immediate poll so we have values right away
        pollPower()
        pollCycleHealth()

        // Subscribe to power source changes
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let rlSource = IOPSNotificationCreateRunLoopSource({ _ in
            // On any power source change, re-poll
            PowerMonitor.shared?.pollPower()
            PowerMonitor.shared?.pollCycleHealth()
        }, nil).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), rlSource, .defaultMode)
        powerSourceRunLoop = Unmanaged.passRetained(rlSource)

        // Safety: also poll every 60s in case notifications are missed
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in
            self?.pollPower()
            self?.pollCycleHealth()
        }
        t.resume()
        periodicTimer = t
    }

    func stop() {
        if let s = powerSourceRunLoop?.takeRetainedValue() {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), s, .defaultMode)
        }
        powerSourceRunLoop?.release()
        powerSourceRunLoop = nil
        periodicTimer?.cancel()
    }

    // Singleton for callback trampoline
    static var shared: PowerMonitor?

    private var periodicTimer: DispatchSourceTimer?

    private func pollPower() {
        guard let snap = readBatterySnapshot() else { return }
        if snap != lastBattery {
            lastBattery = snap
            onBatteryChange?(snap)
        }
    }

    private func pollCycleHealth() {
        let ch = readCycleHealth()
        if ch != lastCycleHealth {
            lastCycleHealth = ch
            onCycleHealthChange?(ch)
        }
    }

    private func readBatterySnapshot() -> BatterySnapshot? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, ps).takeUnretainedValue() as? [String: Any] else { continue }
            let type = desc[kIOPSTypeKey as String] as? String
            if type == kIOPSInternalBatteryType {
                let current = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 0
                let max = desc[kIOPSMaxCapacityKey as String] as? Int ?? 1
                let percent = Int((Double(current) / Double(max)) * 100.0 + 0.5)
                let source = desc[kIOPSPowerSourceStateKey as String] as? String ?? kIOPSBatteryPowerValue
                let chargeState = (source == kIOPSACPowerValue) ? "Charger" : "Battery"
                return BatterySnapshot(percent: max(0, min(100, percent)), chargeState: chargeState)
            }
        }
        return nil
    }

    private func readCycleHealth() -> CycleHealthSnapshot {
        // Try AppleSmartBattery registry keys
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        defer { if service != 0 { IOObjectRelease(service) } }

        var cycle: Int?
        var healthPct: Int?

        if service != 0 {
            func prop(_ key: String) -> Int? {
                guard let v = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
                if CFGetTypeID(v) == CFNumberGetTypeID() {
                    var out: Int32 = 0
                    if CFNumberGetValue((v as! CFNumber), .sInt32Type, &out) { return Int(out) }
                }
                return nil
            }
            let maxCap = prop("MaxCapacity")
            let designCap = prop("DesignCapacity")
            cycle = prop("CycleCount")
            if let maxCap = maxCap, let designCap = designCap, designCap > 0 {
                healthPct = Int((Double(maxCap) / Double(designCap)) * 100.0 + 0.5)
            }
        }

        return CycleHealthSnapshot(cycleCount: cycle, healthPercent: healthPct)
    }
}

// MARK: - Lock / Unlock monitor

final class LockStateMonitor: NSObject {
    enum UseState: String { case Lock = "Lock", Unlock = "Unlock" }
    var onChange: ((UseState) -> Void)?

    private var last: UseState?

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(onLocked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(onUnlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    @objc private func onLocked() {
        emit(.Lock)
    }
    @objc private func onUnlocked() {
        emit(.Unlock)
    }

    private func emit(_ state: UseState) {
        if state != last {
            last = state
            onChange?(state)
        }
    }

    // For startup/shutdown hooks
    func force(_ state: UseState) { emit(state) }
    func lastState() -> UseState? { last }
}

// MARK: - Key counts (safe sink; no global key capture here)

final class KeyCountSink {
    private let queue = DispatchQueue(label: "um.keycounts")
    private var counts: [Int: Int] = [:]
    private var lastSnapshotDay: String = KeyCountSink.dayKey(Date())
    private let currentURL: URL
    private let paths: UMPaths

    init(paths: UMPaths) {
        self.paths = paths
        self.currentURL = paths.keyCountsCurrent
        loadExisting()
        startPeriodicFlushAndDailySnapshot()
    }

    // Safe API you can call from your own app with explicit user consent
    func increment(keyCode: Int, by delta: Int = 1) {
        queue.async {
            self.counts[keyCode, default: 0] += delta
        }
    }

    private func loadExisting() {
        if let data = try? Data(contentsOf: currentURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Int] {
            for (k, v) in obj {
                if let kk = Int(k) { counts[kk] = v }
            }
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    private func flushCurrent() {
        let payload: [String: Int] = counts
        let strKeyed = Dictionary(uniqueKeysWithValues: payload.map { (String($0.key), $0.value) })
        if let data = try? JSONSerialization.data(withJSONObject: strKeyed, options: [.prettyPrinted]) {
            do {
                let tmp = currentURL.appendingPathExtension("tmp")
                try data.write(to: tmp, options: .atomic)
                try? FileManager.default.removeItem(at: currentURL)
                try FileManager.default.moveItem(at: tmp, to: currentURL)
            } catch {
                os_log("key_counts_current write failed: %{public}@", "\(error)")
            }
        }
    }

    private func snapshotIfNewDay() {
        let today = KeyCountSink.dayKey(Date())
        if today != lastSnapshotDay {
            lastSnapshotDay = today
            // Write a dated snapshot
            let url = paths.dailyKeyCountsSnapshotURL(Date())
            let payload: [String: Int] = counts
            let strKeyed = Dictionary(uniqueKeysWithValues: payload.map { (String($0.key), $0.value) })
            if let data = try? JSONSerialization.data(withJSONObject: strKeyed, options: [.prettyPrinted]) {
                do { try data.write(to: url, options: .atomic) }
                catch { os_log("daily key_counts snapshot failed: %{public}@", "\(error)") }
            }
        }
    }

    private func startPeriodicFlushAndDailySnapshot() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 10, repeating: 10) // every 10s
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.flushCurrent()
            self.snapshotIfNewDay()
        }
        t.resume()
    }

    // Graceful shutdown
    func flush() {
        queue.sync { flushCurrent() }
    }
}

// MARK: - Orchestrator

final class UsageMonitor {
    private let paths = UMPaths()
    private let batteryWriter: BatchFileWriter
    private let stateWriter: BatchFileWriter
    private let cyclesWriter: BatchFileWriter
    private let power = PowerMonitor()
    private let lockMon = LockStateMonitor()
    private let keySink: KeyCountSink
    private var lastChargeState: String?
    private var shuttingDown = false

    init() {
        batteryWriter = BatchFileWriter(url: paths.batteryCSV, header: "EntryTime,BatteryPercent")
        stateWriter   = BatchFileWriter(url: paths.stateCSV,   header: "EntryTime,UseState,ChargeState")
        cyclesWriter  = BatchFileWriter(url: paths.cyclesCSV,  header: "EntryTime,ChargeCycleCount,BatteryHealthPercent")
        keySink = KeyCountSink(paths: paths)

        // Power change callbacks
        PowerMonitor.shared = power
        power.onBatteryChange = { [weak self] snap in
            self?.handleBatteryChange(snap)
        }
        power.onCycleHealthChange = { [weak self] ch in
            self?.handleCycleHealthChange(ch)
        }

        // Lock/unlock callbacks
        lockMon.onChange = { [weak self] state in
            self?.writeState(useState: state.rawValue)
        }
    }

    func start() {
        // Startup "Unlock" entry immediately (as requested)
        lockMon.start()
        power.start()
        writeState(useState: LockStateMonitor.UseState.Unlock.rawValue)

        // Trap signals for graceful shutdown
        trapSignals()
        os_log("UsageMonitor started")
    }

    private func handleBatteryChange(_ s: BatterySnapshot) {
        let now = iso8601.string(from: Date())
        batteryWriter.appendLine("\(now),\(s.percent)")

        if s.chargeState != lastChargeState {
            lastChargeState = s.chargeState
            // Log to state file when charge state flips
            writeState(useState: lockMon.lastState()?.rawValue ?? "Unlock", explicitCharge: s.chargeState)
        }
    }

    private func handleCycleHealthChange(_ c: CycleHealthSnapshot) {
        let now = iso8601.string(from: Date())
        let cc = (c.cycleCount != nil) ? String(c.cycleCount!) : ""
        let hp = (c.healthPercent != nil) ? String(c.healthPercent!) : ""
        cyclesWriter.appendLine("\(now),\(cc),\(hp)")
    }

    private func writeState(useState: String, explicitCharge: String? = nil) {
        // Use last known charge state unless given
        let charge = explicitCharge ?? (lastChargeState ?? currentChargeStateGuess())
        let now = iso8601.string(from: Date())
        stateWriter.appendLine("\(now),\(useState),\(charge)")
    }

    private func currentChargeStateGuess() -> String {
        // quick poll for best effort
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, ps).takeUnretainedValue() as? [String: Any] else { continue }
            let type = desc[kIOPSTypeKey as String] as? String
            if type == kIOPSInternalBatteryType {
                let source = desc[kIOPSPowerSourceStateKey as String] as? String ?? kIOPSBatteryPowerValue
                return (source == kIOPSACPowerValue) ? "Charger" : "Battery"
            }
        }
        return "Battery"
    }

    private func trapSignals() {
        func install(_ sig: Int32) {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.gracefulShutdown(signal: sig) }
            src.resume()
        }
        install(SIGTERM); install(SIGINT); install(SIGHUP)
    }

    private func gracefulShutdown(signal: Int32) {
        guard !shuttingDown else { return }
        shuttingDown = true
        os_log("Received signal %{public}d, shutting down...", signal)
        // Write a pre-shutdown Lock entry
        writeState(useState: LockStateMonitor.UseState.Lock.rawValue)
        // Flush everything
        batteryWriter.stop()
        stateWriter.stop()
        cyclesWriter.stop()
        keySink.flush()
        power.stop()
        // Small delay to ensure OS flush
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            exit(0)
        }
    }
}

// MARK: - Main

let monitor = UsageMonitor()
monitor.start()

// Keep the process alive
RunLoop.main.run()
