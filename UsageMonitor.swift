#!/usr/bin/env swift

import Foundation
import Cocoa
import IOKit.ps
import IOKit
import Darwin

// UsageMonitor Files
let DIRECTORY = URL(fileURLWithPath: "/Users/Ericgong/Library/UsageMonitor")

/*
BatteryChargeLog    | Header: EntryTime,BatteryPercent,PowerSource  | Line: 2000-01-01T12:34:56Z,099,0      | 26 characters
BatteryHealthLog    | Header: EntryTime,BatteryHealth,ChargeCycle   | Line: 2000-01-01T12:34:56Z,099,00000  | 30 characters
ScreenStateLog      | Header: EntryTime,ScreenState                 | Line: 2000-01-01T12:34:56Z,0          | 22 characters
KeyFrequencyLog     | Simple JSON Object
*/

let BatteryChargeLog = DIRECTORY.appendingPathComponent("BatteryCharge.csv") 
let BatteryHealthLog = DIRECTORY.appendingPathComponent("BatteryHealth.csv")
let ScreenStateLog = DIRECTORY.appendingPathComponent("ScreenState.csv")
let KeyFrequencyLog = DIRECTORY.appendingPathComponent("KeyFrequency.json")

// State Mappings
enum ScreenState: Int, CustomStringConvertible {
    case Unlocked = 0
    case Locked = 1
    var description: String { String(rawValue) }
    var label: String { self == .Locked ? "Locked" : "Unlocked" }
}

enum PowerSource: Int, CustomStringConvertible {
    case Battery = 0
    case Charger = 1
    var description: String { String(rawValue) }
    var label: String { self == .Battery ? "Battery" : "Charger" }
}

// Helper Function
func now() -> String { ISO8601DateFormatter().string(from: Date()) }

