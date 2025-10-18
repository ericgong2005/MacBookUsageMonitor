#!/usr/bin/env swift

import Foundation
import Cocoa
import IOKit.ps
import IOKit
import Darwin

import UsageMonitorUtilities

// UsageMonitor Files
let DIRECTORY = URL(fileURLWithPath: "/Users/Ericgong/Library/UsageMonitor")
let BACKUPDIRECTORY = DIRECTORY.appendingPathComponent("BackupLogs") 

let BatteryChargeLog = DIRECTORY.appendingPathComponent("BatteryChargeLog") 
let BatteryHealthLog = DIRECTORY.appendingPathComponent("BatteryHealthLog")
let ScreenStateLog = DIRECTORY.appendingPathComponent("ScreenStateLog")
let KeyFrequencyLog = DIRECTORY.appendingPathComponent("KeyFrequencyLog.json")

let LastLogTimeFile = DIRECTORY.appendingPathComponent("LastLogTime")
let LastBackUpTimeFile = DIRECTORY.appendingPathComponent("LastBackUpTime")

// File Creation and initial Start-up
let fm = FileManager.default

func CreateFiles() {
    try? fm.createDirectory(at: DIRECTORY, withIntermediateDirectories: true, attributes: nil)

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

var CurrentBatteryChargeEntry: BatteryChargeEntry? = nil
var CurrentBatteryHealthEntry: BatteryHealthEntry? = nil
var CurrentScreenStateEntry: ScreenStateEntry? = nil
var CurrentKeyFrequency: [String:Int] = [:] 
var KeyPressCounter: Int = 0

var LastLogTime: UInt32 = 0
var LastBackUpTime: UInt32 = 0

func InitializeFileValues() {
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

        guard let CurrentScreenStateEntry else { return }  
        if CurrentScreenStateEntry.ScreenState == .unlocked {
            var toAppend = Data()
            ScreenStateEntry(EntryTime: LastLogTime, ScreenState: .locked).encode(into: &toAppend)
            CurrentScreenStateEntry = ScreenStateEntry(EntryTime: now(), ScreenState: .unlocked)
            CurrentScreenStateEntry.encode(into: &toAppend)
            AtomicAppend(toAppend, to: ScreenStateLog)
            AtomicTimeUpdate(at: LastLogTimeFile)
        } 
    }
    return
}

func StartKeyMonitor() {
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
                CurrentKeyFrequency[String(code), default: 0] += 1
                KeyPressCounter += 1
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

func LogKeyFrequency() {
    if KeyPressCounter > 0 {
        do {
            if let data = try JSONSerialization.data(withJSONObject: CurrentKeyFrequency, options: [.prettyPrinted, .sortedKeys]) {
                try data.write(to: KeyFrequencyLog, options: .atomic)
            }
            AtomicTimeUpdate(at: LastLogTimeFile)
            KeyPressCounter = 0
        } catch {
            print("Log Key Failed at \(NowString())")
            return
        }
    }
}

func LogScreenState(ScreenState: ScreenStateEnum) {
    var toAppend = Data()
    CurrentScreenStateEntry = ScreenStateEntry(EntryTime: now(), ScreenState: ScreenState)
    CurrentScreenStateEntry.encode(into: &toAppend)
    AtomicAppend(toAppend, to: ScreenStateLog)
    AtomicTimeUpdate(at: LastLogTimeFile)
}

func LogBatteryState() {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return }
    defer { IOObjectRelease(service) }

    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
        let dict = props?.takeRetainedValue() as? [String: Any] else { return }
}

// Main Code
CreateFiles()
InitializeFileValues()

StartKeyMonitor()

// Screen State writes happen immediately upon the event
DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil) { _ in
    LogScreenState(.locked)
}
DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: nil) { _ in
    LogScreenState(.unlocked)
}

// Log Keystroke Frequencies and Battery every minute
Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in LogKeyFrequency() }


