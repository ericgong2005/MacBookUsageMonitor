#!/usr/bin/env swift
import Foundation
import Cocoa

let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: CGEventMask(mask),
    callback: { _, type, event, _ in
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .keyDown:
            print("keyDown: \(code)")
        case .flagsChanged:
            print("flagsChanged: \(code)")
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    },
    userInfo: nil
) else {
    fputs("Need Accessibility permission: System Settings → Privacy & Security → Accessibility\n", stderr)
    exit(1)
}

let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

print("Printing key codes… (Ctrl+C to quit)")
RunLoop.current.run()
