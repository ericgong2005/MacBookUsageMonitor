import Foundation
import Cocoa
import IOKit.ps
import IOKit
import Darwin

import UsageMonitorUtilities

@MainActor
@main
struct UsageMonitor {
    static let DIRECTORY = URL(fileURLWithPath: "/Users/Ericgong/Library/UsageMonitor")
    static let BACKUPDIRECTORY = DIRECTORY.appendingPathComponent("BackupLogs")

    static let BatteryChargeLog = DIRECTORY.appendingPathComponent("BatteryChargeLog")
    static let BatteryHealthLog = DIRECTORY.appendingPathComponent("BatteryHealthLog")
    static let ScreenStateLog = DIRECTORY.appendingPathComponent("ScreenStateLog")
    static let KeyFrequencyLog = DIRECTORY.appendingPathComponent("KeyFrequencyLog.json")

    static let LastLogTimeFile = DIRECTORY.appendingPathComponent("LastLogTime")
    static let LastBackUpTimeFile = DIRECTORY.appendingPathComponent("LastBackUpTime")
    
    static func CreateFiles() {
        let fm = FileManager.default
        
        try? fm.createDirectory(at: DIRECTORY, withIntermediateDirectories: true, attributes: nil)
        try? fm.createDirectory(at: BACKUPDIRECTORY, withIntermediateDirectories: true, attributes: nil)

        if !fm.fileExists(atPath: BatteryChargeLog.path) {
            fm.createFile(atPath: BatteryChargeLog.path, contents: Data(), attributes: nil)
        }
        if !fm.fileExists(atPath: BatteryHealthLog.path) {
            fm.createFile(atPath: BatteryHealthLog.path, contents: Data(), attributes: nil)
        }
        if !fm.fileExists(atPath: ScreenStateLog.path) {
            fm.createFile(atPath: ScreenStateLog.path, contents: Data(), attributes: nil)
        }
        if !FileManager.default.fileExists(atPath: KeyFrequencyLog.path) {
            try? Data("{}".utf8).write(to: KeyFrequencyLog)
        }

        if !fm.fileExists(atPath: LastLogTimeFile.path) {
            fm.createFile(atPath: LastLogTimeFile.path, contents: Data(), attributes: nil)
        }
        if !fm.fileExists(atPath: LastBackUpTimeFile.path) {
            fm.createFile(atPath: LastBackUpTimeFile.path, contents: Data(), attributes: nil)
        }
    }

    static var CurrentBatteryChargeEntry: BatteryChargeEntry? = nil
    static var CurrentBatteryHealthEntry: BatteryHealthEntry? = nil
    static var CurrentScreenStateEntry: ScreenStateEntry? = nil
    static var CurrentKeyFrequency: [String:Int] = [:]
    static var KeyPressCounter: Int = 0

    static var LastLogTime: UInt32 = 0
    static var LastBackUpTime: UInt32 = 0

    static func InitializeFileValues() {
        CurrentKeyFrequency = (try? JSONSerialization.jsonObject(with: Data(contentsOf: KeyFrequencyLog)) as? [String:Int]) ?? [:]

        do {
            let data = try Data(contentsOf: LastBackUpTimeFile)
            if data.count >= 4 {
                LastBackUpTime = data.readInteger(at: data.count - 4, as: UInt32.self)
            }
        } catch {
            LastBackUpTime = 0
        }

        do {
            let data = try Data(contentsOf: LastLogTimeFile)
            if data.count >= 4 {
                LastLogTime = data.readInteger(at: data.count - 4, as: UInt32.self)
            }
        } catch {
            return
        }

        let elapsed = now() - LastLogTime
        if elapsed > 600 {
            do {
                let handle = try FileHandle(forReadingFrom: ScreenStateLog)
                defer { try? handle.close() }
                let fileSize = try handle.seekToEnd()
                if fileSize >= UInt64(ScreenStateEntry.byteSize) {
                    let start = fileSize - UInt64(ScreenStateEntry.byteSize)
                    try handle.seek(toOffset: start)
                    let chunk = try handle.read(upToCount: ScreenStateEntry.byteSize) ?? Data()
                    if chunk.count == ScreenStateEntry.byteSize {
                        CurrentScreenStateEntry = ScreenStateEntry.decode(from: chunk, at: 0)
                    }
                }
            } catch {
                return
            }

            guard let entry = CurrentScreenStateEntry else { return }
            if entry.ScreenState == .unlocked {
                var toAppend = Data()
                ScreenStateEntry(EntryTime: LastLogTime, ScreenState: .locked).encode(into: &toAppend)
                let entry = ScreenStateEntry(EntryTime: now(), ScreenState: .unlocked)
                entry.encode(into: &toAppend)
                CurrentScreenStateEntry = entry
                AtomicAppend(toAppend, to: ScreenStateLog)
                _ = AtomicTimeUpdate(at: LastLogTimeFile)
            }
        }
        return
    }

    static func StartKeyMonitor() {
        let mask: CGEventMask =
            (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)) |
            (CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue))

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, t, e, _ in
                if t == .keyDown || t == .flagsChanged {
                    let code = UInt16(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode))
                    Task { @MainActor in
                        Self.CurrentKeyFrequency[String(code), default: 0] += 1
                        Self.KeyPressCounter += 1
                    }
                }
                return Unmanaged.passUnretained(e)
            },
            userInfo: nil
        ) else {
            print("Need Accessibility permission")
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    static func LogKeyFrequency() {
        if KeyPressCounter > 0 {
            do {
                if let data = try? JSONSerialization.data(withJSONObject: CurrentKeyFrequency, options: [.prettyPrinted, .sortedKeys]) {
                    try data.write(to: KeyFrequencyLog, options: .atomic)
                }
                _ = AtomicTimeUpdate(at: LastLogTimeFile)
                KeyPressCounter = 0
            } catch {
                print("Log Key Failed at \(NowString())")
                return
            }
        }
    }

    static func LogScreenState(ScreenState: ScreenStateEnum) {
        var toAppend = Data()
        let entry = ScreenStateEntry(EntryTime: now(), ScreenState: ScreenState)
        entry.encode(into: &toAppend)
        CurrentScreenStateEntry = entry
        AtomicAppend(toAppend, to: ScreenStateLog)
        _ = AtomicTimeUpdate(at: LastLogTimeFile)
    }

    static func LogBatteryState() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
        let dict = props?.takeRetainedValue() as? [String: Any] else { return }
        let batteryData = dict["BatteryData"] as? [String: Any]
        
        let entryTime: UInt32 = now()

        let voltageNum = (dict["AppleRawBatteryVoltage"] as? NSNumber)
            ?? (dict["Voltage"] as? NSNumber)
            ?? (batteryData?["Voltage"] as? NSNumber)
        let voltage: Int16 = voltageNum.map { Int16(truncating: $0) } ?? 0

        let amperage: Int16 = (dict["Amperage"] as? NSNumber).map { Int16(truncating: $0) } ?? 0
        let rawCurrentCapacity: Int16 = (dict["AppleRawCurrentCapacity"] as? NSNumber).map { Int16(truncating: $0) } ?? 0

        let currentCapacityNum = (dict["CurrentCapacity"] as? NSNumber) ?? (batteryData?["StateOfCharge"] as? NSNumber)
        let currentCapacity: Int8 = currentCapacityNum.map { Int8(truncating: $0) } ?? 0

        let cellVoltagesNums = (batteryData?["CellVoltage"] as? [NSNumber]) ?? []
        let cellV0: Int16 = cellVoltagesNums.indices.contains(0) ? Int16(truncating: cellVoltagesNums[0]) : 0
        let cellV1: Int16 = cellVoltagesNums.indices.contains(1) ? Int16(truncating: cellVoltagesNums[1]) : 0
        let cellV2: Int16 = cellVoltagesNums.indices.contains(2) ? Int16(truncating: cellVoltagesNums[2]) : 0

        let presentDODNums = (batteryData?["PresentDOD"] as? [NSNumber]) ?? []
        let dod0: Int8 = presentDODNums.indices.contains(0) ? Int8(truncating: presentDODNums[0]) : 0
        let dod1: Int8 = presentDODNums.indices.contains(1) ? Int8(truncating: presentDODNums[1]) : 0
        let dod2: Int8 = presentDODNums.indices.contains(2) ? Int8(truncating: presentDODNums[2]) : 0

        let BatteryChargeNow = BatteryChargeEntry(
            EntryTime: entryTime,
            Amperage: amperage,
            RawCurrentCapacity: rawCurrentCapacity,
            Voltage: voltage,
            CellVoltage0: cellV0,
            CellVoltage1: cellV1,
            CellVoltage2: cellV2,
            CurrentCapacity: currentCapacity,
            PresentDOD0: dod0,
            PresentDOD1: dod1,
            PresentDOD2: dod2
        )
        
        let BatteryChargeChanged : Bool = {
            if let prev = CurrentBatteryChargeEntry {
                return !BatteryChargeEntry.equal(prev, BatteryChargeNow)
            } else {
                return true
            }
        }()
        
        if BatteryChargeChanged {
            var data = Data(capacity: BatteryChargeEntry.byteSize)
            let entry = BatteryChargeNow
            entry.encode(into: &data)
            AtomicAppend(data, to: BatteryChargeLog)
            CurrentBatteryChargeEntry = BatteryChargeNow
        }

        let cycleCount: UInt16 = (dict["CycleCount"] as? NSNumber).map { UInt16(truncating: $0) } ?? 0
        let rawMaxCapacity: Int16 = (dict["AppleRawMaxCapacity"] as? NSNumber).map { Int16(truncating: $0) } ?? 0

        let qmaxNums = (batteryData?["Qmax"] as? [NSNumber]) ?? []
        let q0: Int16 = qmaxNums.indices.contains(0) ? Int16(truncating: qmaxNums[0]) : 0
        let q1: Int16 = qmaxNums.indices.contains(1) ? Int16(truncating: qmaxNums[1]) : 0
        let q2: Int16 = qmaxNums.indices.contains(2) ? Int16(truncating: qmaxNums[2]) : 0

        let weightedRaNums = (batteryData?["WeightedRa"] as? [NSNumber]) ?? []
        let ra0: Int8 = weightedRaNums.indices.contains(0) ? Int8(truncating: weightedRaNums[0]) : 0
        let ra1: Int8 = weightedRaNums.indices.contains(1) ? Int8(truncating: weightedRaNums[1]) : 0
        let ra2: Int8 = weightedRaNums.indices.contains(2) ? Int8(truncating: weightedRaNums[2]) : 0

        let externalConnected: Int8 = (dict["ExternalConnected"] as? NSNumber).map { Int8(truncating: $0) } ?? 0

        let BatteryHealthNow = BatteryHealthEntry(
            EntryTime: entryTime,
            CycleCount: cycleCount,
            RawMaxCapacity: rawMaxCapacity,
            QMax0: q0, QMax1: q1, QMax2: q2,
            WeightedRa0: ra0, WeightedRa1: ra1, WeightedRa2: ra2,
            ExternalConnected: externalConnected
        )
        
        let BatteryHealthChanged : Bool = {
            if let prev = CurrentBatteryHealthEntry {
                return !BatteryHealthEntry.equal(prev, BatteryHealthNow)
            } else {
                return true
            }
        }()
        
        if BatteryHealthChanged {
            var data = Data(capacity: BatteryHealthEntry.byteSize)
            let entry = BatteryHealthNow
            entry.encode(into: &data)
            AtomicAppend(data, to: BatteryHealthLog)
            CurrentBatteryHealthEntry = BatteryHealthNow
        }
        
        _ = AtomicTimeUpdate(at: LastLogTimeFile)
    }
    
    static func BackupLogs() {
        let cal = Calendar.current
        let nowDate = Date()

        if LastBackUpTime != 0 {
            let last = Date(timeIntervalSinceReferenceDate: TimeInterval(LastBackUpTime))
            if cal.isDate(last, inSameDayAs: nowDate) { return }
        }

        let dateString = NowString()

        try? FileManager.default.createDirectory(at: BACKUPDIRECTORY, withIntermediateDirectories: true, attributes: nil)

        let chargeBackup = BACKUPDIRECTORY.appendingPathComponent("BatteryChargeLog_\(dateString)")
        if !FileManager.default.fileExists(atPath: chargeBackup.path) {
            _ = clonefile(BatteryChargeLog.path, chargeBackup.path, 0)
        }
        
        let healthBackup = BACKUPDIRECTORY.appendingPathComponent("BatteryHealthLog_\(dateString)")
        if !FileManager.default.fileExists(atPath: healthBackup.path) {
            _ = clonefile(BatteryHealthLog.path, healthBackup.path, 0)
        }

        let screenBackup = BACKUPDIRECTORY.appendingPathComponent("ScreenStateLog_\(dateString)")
        if !FileManager.default.fileExists(atPath: screenBackup.path) {
            _ = clonefile(ScreenStateLog.path, screenBackup.path, 0)
        }

        let KeyFrequencyBackup = BACKUPDIRECTORY.appendingPathComponent("KeyFrequencyLog_\(dateString).json")
        if !FileManager.default.fileExists(atPath: KeyFrequencyBackup.path) {
            _ = clonefile(KeyFrequencyLog.path, KeyFrequencyBackup.path, 0)
        }
        
        let fm = FileManager.default
        let dirPath = BACKUPDIRECTORY.path
        
        if let files = try? fm.contentsOfDirectory(atPath: dirPath) {
            for f in files where (f.hasPrefix("BatteryChargeLog_") || f.hasPrefix("BatteryHealthLog_") || f.hasPrefix("ScreenStateLog_")) && !f.contains(dateString) {
                try? fm.removeItem(atPath: "\(dirPath)/\(f)")
            }
        }

        _ = AtomicTimeUpdate(at: LastBackUpTimeFile)
        LastBackUpTime = now()
    }

    static func main() {
        CreateFiles()
        InitializeFileValues()

        StartKeyMonitor()
        
        BackupLogs()

        // Screen State writes happen immediately upon the event
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil) { _ in
            Task { @MainActor in LogScreenState(ScreenState: .locked)}
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: nil) { _ in
            Task { @MainActor in LogScreenState(ScreenState: .unlocked)}
        }

        // Log Keystroke Frequencies
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in LogKeyFrequency()} }
        
        // Check Battery every minute
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in LogBatteryState()} }
        
        // Check Backup every 12 hours
        Timer.scheduledTimer(withTimeInterval: 43200, repeats: true) { _ in Task { @MainActor in BackupLogs()} }
                
        RunLoop.main.run()
    }
}
