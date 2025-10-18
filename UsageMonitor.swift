#!/usr/bin/env swift

import Foundation
import Cocoa
import IOKit.ps
import IOKit
import Darwin

import UsageMonitorUtilities

// UsageMonitor Files
let DIRECTORY = URL(fileURLWithPath: "/Users/Ericgong/Library/UsageMonitor")

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
var CurrentKeyFrequency: [String:Int]? = nil 

var LastLogTime: UInt32? = nil
var LastBackUpTime: UInt32? = nil

func ReadFileValues() {
    CurrentKeyFrequency = (try? JSONSerialization.jsonObject(with: Data(contentsOf: KeyFrequencyLog)) as? [String:Int]) ?? [:]

    do {
        let data = try Data(contentsOf: LastBackUpTimeFile)
        if data.count >= 4 {
            LastBackUpTime = data.readInteger(at: data.count - 4, as: UInt32.self)
        }
    } catch {
        LastBackUpTime = nil
    }

    do {
        let data = try Data(contentsOf: LastLogTimeFile)
        if data.count >= 4 {
            LastLogTime = data.readInteger(at: data.count - 4, as: UInt32.self)
        }
    } catch {
        LastLogTime = nil
        return
    }

    guard let LastLogTime else { return }  
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
            if let wh = try? FileHandle(forWritingTo: ScreenStateLog) {
                do {
                    try wh.seekToEnd()
                    try wh.write(contentsOf: toAppend)
                } catch {
                    return 
                }
                try? wh.close()
            }
        } 
    }
    return
}

// Main Code
CreateFiles()
ReadFileValues()



