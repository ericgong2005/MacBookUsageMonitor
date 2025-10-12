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

    var lastRunDate: Date? = nil
    if let lastStr = try? String(contentsOfFile: lastRunFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
       let d = df.date(from: lastStr) {
        lastRunDate = d
    }

    // If today is a multiple of 5, only run if we haven't run today yet
    if day % 5 == 0 {
        if let last = lastRunDate, Calendar.current.isDate(last, inSameDayAs: todayDate) {
            return false
        }
        return true
    }

    // Otherwise, run if last run was more 5 days ago (catch-up)
    guard let last = lastRunDate else { return true }
    if let diff = Calendar.current.dateComponents([.day], from: last, to: todayDate).day,
       diff >= 5 {
        return true
    }

    return false
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

// Clean CSV by removing middle duplicates
func cleanCSV(inputPath: String, outputPath: String) throws {
    let contents = try String(contentsOfFile: inputPath, encoding: .utf8)
    let lines = contents.split(separator: "\n").map(String.init)
    guard !lines.isEmpty else { return }

    let header = lines.first!
    var result = [header]
    var prevRest = ""
    var group = [String]()

    for line in lines.dropFirst() {
        let comps = line.split(separator: ",", omittingEmptySubsequences: false)
        guard comps.count > 1 else { continue }
        let rest = comps.dropFirst().joined(separator: ",")

        if rest == prevRest {
            group.append(line)
        } else {
            if group.count > 1 {
                result.append(group.first!)
                result.append(group.last!)
            } else if let single = group.first {
                result.append(single)
            }
            group = [line]
            prevRest = rest
        }
    }

    if group.count > 1 {
        result.append(group.first!)
        result.append(group.last!)
    } else if let single = group.first {
        result.append(single)
    }

    try result.joined(separator: "\n")
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

    try? cleanCSV(inputPath: batteryPath, outputPath: batteryTemp)
    try? cleanCSV(inputPath: screenPath, outputPath: screenTemp)

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