#!/usr/bin/swift

import Foundation

// Compile with: swiftc UsageMonitorMaintenance.swift -o UsageMonitorMaintenance

// Concurrency Lock
final class FileLock {
    private let url: URL
    private var fd: Int32 = -1

    init(_ url: URL) { self.url = url }

    func lock() throws {
        if fd == -1 {
            fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            if fd == -1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }

        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                return
            }
            let e = errno
            if e == EINTR { continue }
            if e == EWOULDBLOCK {
                Thread.sleep(forTimeInterval: 10)
                continue
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e))
        }
    }

    func unlock() {
        if fd != -1 {
            _ = flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    deinit { unlock() }
}

// Configuration
let fileManager = FileManager.default
let baseDir = NSString(string: "/Users/Ericgong/Library/UsageMonitor").expandingTildeInPath
let logDir = "\(baseDir)/Logs"
let lastRunFile = "\(logDir)/PreviousLogDate.txt"
let todayDate = Date()
let calendar = Calendar.current
let day = calendar.component(.day, from: todayDate)
let dateFormatter = DateFormatter()
dateFormatter.dateFormat = "yyyy-MM-dd"
let todayString = dateFormatter.string(from: todayDate)

let lockURL = URL(fileURLWithPath: baseDir).appendingPathComponent("UsageMonitor.lock")
let GlobalLock = FileLock(lockURL)

func log(_ msg: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    print("[\(timestamp)] \(msg)")
}

// Decide if the script should run today
func isUpdateDay() -> Bool {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"

    if let lastStr = try? String(contentsOfFile: lastRunFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
       let lastRun = df.date(from: lastStr) {
        return !Calendar.current.isDate(lastRun, inSameDayAs: todayDate)
    }

    return true
}

// Wait if file was updated recently (avoid overlap with 10-min logger)
func waitIfRecentlyUpdated(filePath: String) {
    guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8),
          let lastLine = contents.split(separator: "\n").last else { return }

    let timeToken = lastLine.split(separator: ",").first ?? ""
    let timeStr = String(timeToken)

    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    if let lastDate = fmt.date(from: timeStr) {
        let diff = Date().timeIntervalSince(lastDate) / 60
        if diff > 8 {
            Thread.sleep(forTimeInterval: 300)
        }
    }
}

// Clean CSV files
@inline(__always)
func regexReplace(_ text: String, pattern: String, template: String,
                  options: NSRegularExpression.Options = []) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
}

let iso = ISO8601DateFormatter()

// --- Battery cleaner ---
// Fix joined lines after true/false; then collapse consecutive duplicates keeping the most recent.
func cleanBatteryCSV(inputPath: String, outputPath: String) throws {
    var content = try String(contentsOfFile: inputPath, encoding: .utf8)

    // 1) Fix bad rows where AC ("true"/"false") is glued to the next ISO timestamp.
    content = regexReplace(
        content,
        pattern: #"(?i)\b(true|false)(?=(?:\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z))"#,
        template: "$1\n"
    )

    // 2) Stream once, keeping only the last row in any consecutive block where
    //    (Max,Charge,Cycles,AC) are identical.
    let lines = content.split(whereSeparator: \.isNewline).map(String.init)
    guard !lines.isEmpty else {
        try "".write(toFile: outputPath, atomically: true, encoding: .utf8)
        return
    }

    let header = lines.first!   // Expect "Time,Max,Charge,Cycles,AC"
    var result: [String] = [header]
    var lastRest: String? = nil

    for line in lines.dropFirst() {
        let comps = line.split(separator: ",", omittingEmptySubsequences: false)
        guard comps.count == 5 else { continue }

        let rest = comps.dropFirst().joined(separator: ",")
        if rest == lastRest {
            result.removeLast()
            result.append(line)
        } else {
            result.append(line)
            lastRest = rest
        }
    }

    try result.joined(separator: "\n").appending("\n")
        .write(toFile: outputPath, atomically: true, encoding: .utf8)
}

// --- Screen cleaner ---
// Fix joined rows; keep ScreenOn only when directly between two ScreenUnlocked entries;
// collapse consecutive ScreenOn (keep most recent); drop Lock-Unlock pairs < 30s.
func cleanScreenCSV(inputPath: String, outputPath: String) throws {
    var content = try String(contentsOfFile: inputPath, encoding: .utf8)

    // 1) Fix bad rows where an event name is glued to the next timestamp.
    let eventNames = #"ScriptStarted|ScreenOn|ScreenLocked|ScreenUnlocked"#
    content = regexReplace(
        content,
        pattern: #"(?:"# + eventNames + #")(?=(?:\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z))"#,
        template: "$0\n"
    )

    let lines = content.split(whereSeparator: \.isNewline).map(String.init)
    guard !lines.isEmpty else {
        try "".write(toFile: outputPath, atomically: true, encoding: .utf8)
        return
    }

    // Parse lines to (date,event); skip malformed
    struct Evt { let t: Date; let e: String }
    var events: [Evt] = []
    let header = lines.first!   // Expect "Time,Event"
    for line in lines.dropFirst() {
        let comps = line.split(separator: ",", omittingEmptySubsequences: false)
        guard comps.count == 2 else { continue }
        let tStr = String(comps[0])
        let eStr = String(comps[1])
        guard let t = iso.date(from: tStr) else { continue }
        events.append(Evt(t: t, e: eStr))
    }

    // Single-pass build with small lookahead via a "pending ScreenOn"
    var out: [Evt] = []
    var isUnlocked = false
    var pendingOn: Evt? = nil

    @inline(__always)
    func flushPendingOnBetweenUnlocks() {
        // Append the pending ScreenOn (already the most recent due to overwrites)
        if let p = pendingOn {
            if let last = out.last, last.e == "ScreenOn" {
                // Replace prior ScreenOn if somehow present (shouldn't usually happen)
                _ = out.popLast()
            }
            out.append(p)
            pendingOn = nil
        }
    }

    for ev in events {
        switch ev.e {
        case "ScriptStarted":
            out.append(ev)

        case "ScreenOn":
            if isUnlocked {
                pendingOn = ev
            }
        case "ScreenUnlocked":
            // If the previous kept event is 'ScreenLocked' and gap < 30s, drop the pair.
            if let last = out.last, last.e == "ScreenLocked" {
                if ev.t.timeIntervalSince(last.t) < 30 {
                    _ = out.popLast() // remove ScreenLocked
                    continue
                }
            }

            // If we were already unlocked and we now see another unlock,
            // a pending ScreenOn is *directly between two unlocks* — keep it.
            if isUnlocked { flushPendingOnBetweenUnlocks() }

            out.append(ev)
            isUnlocked = true

        case "ScreenLocked":
            // Lock closes the window; pending 'ScreenOn' was not between two unlocks, drop it.
            pendingOn = nil
            out.append(ev)
            isUnlocked = false

        default:
            // Unknown events: treat like a barrier and keep them; drop pending ScreenOn.
            pendingOn = nil
            out.append(ev)
        }
    }

    // End: if pendingOn remains, it's not between two unlocks -> drop.

    // Now serialize
    var result: [String] = [header]
    for ev in out {
        result.append("\(iso.string(from: ev.t)),\(ev.e)")
    }

    try result.joined(separator: "\n").appending("\n")
        .write(toFile: outputPath, atomically: true, encoding: .utf8)
}

// Main code
try? fileManager.createDirectory(atPath: logDir, withIntermediateDirectories: true)

// Only proceed if it's an update day
if !isUpdateDay() {
    exit(0)
}

log("Starting UsageMonitor maintenance for \(todayString)")

do {
    try GlobalLock.lock()
    defer { GlobalLock.unlock() }

    let batteryPath = "\(baseDir)/battery_log.csv"
    let keyFreqPath = "\(baseDir)/key_frequency.json"
    let screenPath = "\(baseDir)/screen_log.csv"

    waitIfRecentlyUpdated(filePath: screenPath)

    // Clean CSVs
    let batteryTemp = "\(logDir)/battery_clean.csv"
    let screenTemp = "\(logDir)/screen_clean.csv"

    try? cleanBatteryCSV(inputPath: batteryPath, outputPath: batteryTemp)
    try? cleanScreenCSV(inputPath: screenPath, outputPath: screenTemp)

    // Atomically replace originals
    _ = try? fileManager.replaceItemAt(URL(fileURLWithPath: batteryPath),
                                    withItemAt: URL(fileURLWithPath: batteryTemp))
    _ = try? fileManager.replaceItemAt(URL(fileURLWithPath: screenPath),
                                    withItemAt: URL(fileURLWithPath: screenTemp))

    // Archive new copies
    let dateSuffix = todayString
    let batteryArchive = "\(logDir)/battery_log_\(dateSuffix).csv"
    let keyArchive = "\(logDir)/key_frequency_\(dateSuffix).json"
    let screenArchive = "\(logDir)/screen_log_\(dateSuffix).csv"

    try? fileManager.copyItem(atPath: batteryPath, toPath: batteryArchive)
    try? fileManager.copyItem(atPath: keyFreqPath, toPath: keyArchive)
    try? fileManager.copyItem(atPath: screenPath, toPath: screenArchive)

    // Delete older CSV archives (keep JSON)
    if let files = try? fileManager.contentsOfDirectory(atPath: logDir) {
        for f in files where (f.hasPrefix("battery_log_") || f.hasPrefix("screen_log_")) && !f.contains(dateSuffix) {
            try? fileManager.removeItem(atPath: "\(logDir)/\(f)")
        }
    }

    // Record last run date (full date string)
    try? todayString.write(toFile: lastRunFile, atomically: true, encoding: .utf8)

    log("Maintenance complete for \(todayString)")
} catch {
    fputs("Maintenance failed to acquire lock: \(error)\n", stderr)
    exit(1)
}