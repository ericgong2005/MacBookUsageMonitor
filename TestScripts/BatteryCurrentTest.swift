#!/usr/bin/swift

import Foundation
import IOKit.ps

let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()

let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]

// Find the internal battery and read kIOPSCurrentKey
for ps in sources {
    guard
        let desc = IOPSGetPowerSourceDescription(snapshot, ps).takeUnretainedValue() as? [String: Any],
        let type = desc[kIOPSTypeKey as String] as? String,
        type == (kIOPSInternalBatteryType as String)
    else { continue }

    if let num = desc[kIOPSIsChargingKey] {
        print("\(num)")
    } else {
        print("Battery current not available (kIOPSCurrentKey missing).")
    }
}
