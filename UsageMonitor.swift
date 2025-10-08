#!/usr/bin/env swift
import Foundation
import Cocoa
import IOKit.ps
import IOKit

// Compile with swiftc UsageMonitor.swift -o UsageMonitor

// Configuration
let LOG_DIR = URL(fileURLWithPath: "/Users/Ericgong/Library/UsageMonitor")
try? FileManager.default.createDirectory(at: LOG_DIR, withIntermediateDirectories: true)

let batteryCSV = LOG_DIR.appendingPathComponent("battery_log.csv")
let keyFreqJSON = LOG_DIR.appendingPathComponent("key_frequency.json")
let screenCSV  = LOG_DIR.appendingPathComponent("screen_log.csv")

func now() -> String { ISO8601DateFormatter().string(from: Date()) }

// File creation
func createFilesAndHeadersOnce() {
    if !FileManager.default.fileExists(atPath: batteryCSV.path) {
        try? Data("Time,Max,Charge,Cycles,AC\n".utf8).write(to: batteryCSV)
    }
    if !FileManager.default.fileExists(atPath: screenCSV.path) {
        try? Data("Time,Event\n".utf8).write(to: screenCSV)
    }
    if !FileManager.default.fileExists(atPath: keyFreqJSON.path) {
        try? Data("{}".utf8).write(to: keyFreqJSON)
    }
}

// Battery Logging
struct BatteryState: Equatable { var max, charge: Double; var cycles: Int; var ac: Bool }
let batteryQ = DispatchQueue(label: "batteryQ")

var batteryEntries: [(time: String, state: BatteryState)] = []
var lastBattery: BatteryState?

@Sendable func logBattery() {
    guard
        let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
        let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef],
        let src = list.first,
        let d = IOPSGetPowerSourceDescription(snap, src)?.takeUnretainedValue() as? [String:Any]
    else { return }

    let max = (d[kIOPSMaxCapacityKey] as? Double) ?? 0
    let charge = (d[kIOPSCurrentCapacityKey] as? Double) ?? 0
    let ac = (d[kIOPSPowerSourceStateKey] as? String) == "AC Power"

    var cycles = -1
    var it: io_iterator_t = 0
    if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"), &it) == KERN_SUCCESS {
        var s = IOIteratorNext(it)
        while s != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(s, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String:Any],
               let c = dict["CycleCount"] as? Int {
                cycles = c
                break
            }
            s = IOIteratorNext(it)
        }
        IOObjectRelease(it)
    }

    let current = BatteryState(max: max, charge: charge, cycles: cycles, ac: ac)
    let ts = now()

    batteryQ.async {
        if let last = lastBattery, last == current {
            if !batteryEntries.isEmpty {
                batteryEntries[batteryEntries.count - 1].time = ts
            } else {
                batteryEntries.append((ts, current))
            }
        } else {
            batteryEntries.append((ts, current))
            lastBattery = current
        }
    }
}

// Keystroke frequency logging
var keyFreq: [String:Int] =
    (try? JSONSerialization.jsonObject(with: Data(contentsOf: keyFreqJSON)) as? [String:Int]) ?? [:]
let keyQ = DispatchQueue(label: "keyQ")

func startKeyMonitor() {
    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                      place: .headInsertEventTap,
                                      options: .defaultTap,
                                      eventsOfInterest: CGEventMask(mask),
                                      callback: { _, t, e, _ in
        keyQ.async {
            if t == .keyDown {
                let code = UInt16(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode))
                keyFreq[String(code), default: 0] += 1
            } else if t == .flagsChanged {
                let f = e.flags
                if f.contains(.maskCommand)   { keyFreq["cmd", default: 0] += 1 }
                if f.contains(.maskAlternate) { keyFreq["opt", default: 0] += 1 }
                if f.contains(.maskShift)     { keyFreq["shift", default: 0] += 1 }
                if f.contains(.maskControl)   { keyFreq["ctrl", default: 0] += 1 }
            }
        }
        return Unmanaged.passUnretained(e)
    }, userInfo: nil) else {
        print("Need Accessibility permission")
        return
    }

    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0),
                       .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
}

// Screen state logging
enum ScreenState: String {
    case on = "ScreenOn"
    case locked = "ScreenLocked"
    case unlocked = "ScreenUnlocked"
    case sleep = "SystemSleep"
    case wake = "SystemWake"
    case started = "ScriptStarted"
}

let screenQ = DispatchQueue(label: "screenQ")
var screenEvents: [(time: String, state: ScreenState)] = []

func updateScreenState(_ newState: ScreenState) {
    screenQ.async {
        let timestamp = now()
        if let last = screenEvents.last, last.state == newState {
            screenEvents[screenEvents.count - 1].time = timestamp
        } else {
            screenEvents.append((timestamp, newState))
        }
    }
}

// Notifications
DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"),
                                                    object: nil, queue: nil) { _ in
    updateScreenState(.locked)
}
DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                                    object: nil, queue: nil) { _ in
    updateScreenState(.unlocked)
}
DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.system.sleep"),
                                                    object: nil, queue: nil) { _ in
    updateScreenState(.sleep)
}
DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.system.woke"),
                                                    object: nil, queue: nil) { _ in
    updateScreenState(.wake)
}

func writeAll() {
    // Battery
    batteryQ.sync {
        guard !batteryEntries.isEmpty else { return }

        let joined = batteryEntries.map { entry in
            "\(entry.time),\(entry.state.max),\(entry.state.charge),\(entry.state.cycles),\(entry.state.ac)"
        }.joined(separator: "\n") + "\n"

        if let data = joined.data(using: .utf8) {
            if let fh = try? FileHandle(forWritingTo: batteryCSV) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.synchronizeFile()  // ensure disk flush
                try? fh.close()
            } else {
                try? data.write(to: batteryCSV, options: .atomic)
            }
        }

        batteryEntries.removeAll(keepingCapacity: true)
    }

    // Screen
    screenQ.sync {
        guard !screenEvents.isEmpty else { return }

        let joined = screenEvents.map { e in
            "\(e.time),\(e.state.rawValue)"
        }.joined(separator: "\n") + "\n"

        if let data = joined.data(using: .utf8) {
            if let fh = try? FileHandle(forWritingTo: screenCSV) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.synchronizeFile()
                try? fh.close()
            } else {
                try? data.write(to: screenCSV, options: .atomic)
            }
        }

        screenEvents.removeAll(keepingCapacity: true)
    }

    // Keystroke
    keyQ.sync {
        if let data = try? JSONSerialization.data(withJSONObject: keyFreq,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: keyFreqJSON, options: .atomic)
        }
    }

    // Give filesystem a moment to flush
    Thread.sleep(forTimeInterval: 0.5)
}

// Termination handlers
let workspaceCenter = NSWorkspace.shared.notificationCenter
workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                            object: nil, queue: nil) { _ in writeAll() }
workspaceCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                            object: nil, queue: nil) { _ in writeAll() }
workspaceCenter.addObserver(forName: NSWorkspace.willPowerOffNotification,
                            object: nil, queue: nil) { _ in writeAll() }

atexit { writeAll() }
signal(SIGTERM) { _ in writeAll(); exit(0) }
signal(SIGINT)  { _ in writeAll(); exit(0) }

// Begin Execution
createFilesAndHeadersOnce()

print("Monitoring active; logs at \(LOG_DIR.path)")
updateScreenState(.started)
logBattery()
startKeyMonitor()

// 5min battery sampling
Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in logBattery() }

// 15 min screen check
Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { _ in updateScreenState(.on) }

// 30 min write trigger
Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in writeAll() }

RunLoop.main.run()

