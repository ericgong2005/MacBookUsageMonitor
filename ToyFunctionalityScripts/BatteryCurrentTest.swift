#!/usr/bin/swift

import Foundation
import IOKit
import IOKit.ps

func readSmartBatteryDict() -> [String: Any]? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
    return dict
}

// Option A: unwrap explicitly
if let d = readSmartBatteryDict() {
    print(d)
} else {
    print("Smart battery dictionary unavailable")
}

// Option B: if you prefer a default empty dict
// let d = readSmartBatteryDict() ?? [:]
// print(d)
