import SwiftUI
import AppKit
import Charts

@main
struct UsageMonitorViewerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}

struct ContentView: View {
    private let hardcodedFolderPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/UsageMonitor")
        .path
    private let bookmarkKey = "UsageMonitorBookmark"

    @State private var batteryLog: String = ""
    @State private var keyFrequency: String = ""
    @State private var screenLogs: String = ""
    @State private var errorMessage: String?

    var body: some View {
        let entries = parseBatteryCSV(from: batteryLog)
        let sleeps = parseSleepIntervals(from: screenLogs)
        let stats = computeStats(entries: entries, sleepIntervals: sleeps)
        let panelHeight: CGFloat = 240

        ScrollView(.vertical) {
            VStack(spacing: 0) {
                Text("Battery and Charging Statistics")
                    .font(.title)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
                
                HStack(alignment: .top, spacing: 12) {
                    BatteryGraphView(
                        data: entries,
                        sleepIntervals: sleeps
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: panelHeight)

                    StatsPanel(stats: stats)
                        .frame(width: 340)
                        .frame(height: panelHeight)
                }
                .padding(.horizontal)
                .padding(.top, 8)

                Divider()
                
                HStack {
                    Button("Refresh Data") { loadFiles() }
                        .keyboardShortcut("r", modifiers: [.command])

                    if let message = errorMessage {
                        Text(message)
                            .foregroundColor(.red)
                            .padding(.leading)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)

                HStack(spacing: 10) {
                    scrollableColumn(title: "battery_log.csv", content: batteryLog)
                    scrollableColumn(title: "key_frequency.json", content: keyFrequency)
                    scrollableColumn(title: "screen_log.csv", content: screenLogs)
                }
                .padding()
            }
            .onAppear(perform: loadFiles)
        }
    }

    private func scrollableColumn(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .padding(.bottom, 2)

            ScrollView {
                Text(content)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .border(Color.gray.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: 300)
    }

    private func loadFiles() {
        errorMessage = nil
        let targetFolder = URL(fileURLWithPath: hardcodedFolderPath, isDirectory: true)

        if let accessURL = accessFolderWithBookmark(for: targetFolder) {
            readAllFiles(from: accessURL)
            return
        }

        if let grantedURL = askUserForPermission(to: targetFolder) {
            saveBookmark(for: grantedURL)
            readAllFiles(from: grantedURL)
        } else {
            errorMessage = "Access to \(hardcodedFolderPath) not granted."
        }
    }

    private func askUserForPermission(to targetFolder: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Allow Access to UsageMonitor Folder"
        panel.message = "Please grant access to \(targetFolder.path)"
        panel.directoryURL = targetFolder.deletingLastPathComponent()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Allow"

        if panel.runModal() == .OK, let selectedURL = panel.url {
            if selectedURL.path == targetFolder.path {
                return selectedURL
            } else {
                errorMessage = "You must select \(targetFolder.path)"
            }
        }
        return nil
    }

    private func saveBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            errorMessage = "Failed to save bookmark: \(error.localizedDescription)"
        }
    }

    private func accessFolderWithBookmark(for folder: URL) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        do {
            let resolvedURL = try URL(resolvingBookmarkData: data,
                                      options: [.withSecurityScope],
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &isStale)
            if isStale { return nil }
            if resolvedURL.startAccessingSecurityScopedResource() {
                return resolvedURL
            } else {
                return nil
            }
        } catch {
            return nil
        }
    }

    private func readAllFiles(from folderURL: URL) {
        defer { folderURL.stopAccessingSecurityScopedResource() }

        let batteryURL = folderURL.appendingPathComponent("battery_log.csv")
        let keyURL = folderURL.appendingPathComponent("key_frequency.json")
        let screenURL = folderURL.appendingPathComponent("screen_log.csv")

        batteryLog = readFile(at: batteryURL.path) ?? ""
        keyFrequency = readFile(at: keyURL.path) ?? ""
        screenLogs = readFile(at: screenURL.path) ?? ""
    }

    private func readFile(at path: String) -> String? {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // CSV: Time,Max,Charge,Cycles,AC
    private func parseBatteryCSV(from text: String) -> [BatteryEntry] {
        let lines = text.split(separator: "\n")
        guard lines.count > 1 else { return [] }

        var entries: [BatteryEntry] = []
        let df = ISO8601DateFormatter()
        for line in lines.dropFirst() {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 5,
                  let date = df.date(from: String(parts[0])),
                  let maxVal = Double(parts[1]),
                  let charge = Double(parts[2]) else { continue }

            var cycles: Int? = nil
            if let cInt = Int(parts[3]) {
                cycles = cInt
            } else if let cDbl = Double(parts[3]) {
                cycles = Int(cDbl)
            }

            let acStr = String(parts[4]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let ac = (acStr == "true" || acStr == "1" || acStr == "yes")

            let clamped = max(0, min(100, charge))
            entries.append(
                BatteryEntry(timestamp: date,
                             charge: clamped,
                             health: maxVal,
                             cycles: cycles,
                             ac: ac)
            )
        }
        return entries.sorted { $0.timestamp < $1.timestamp }
    }

    // screen_log.csv rules:
    // asleep between ScreenLocked and ScreenUnlocked; if ScreenUnlocked appears without a prior ScreenLocked,
    // use the most recent ScreenOn as the sleep start. Ignore ScriptStarted. Drop sleeps under 5 minutes.
    private func parseSleepIntervals(from text: String) -> [DateInterval] {
        let lines = text.split(separator: "\n")
        guard lines.count > 1 else { return [] }

        let df = ISO8601DateFormatter()
        var events: [(Date, String)] = []

        for line in lines.dropFirst() {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            if parts.count >= 2, let date = df.date(from: String(parts[0])) {
                let evt = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                if evt == "ScriptStarted" { continue }
                events.append((date, evt))
            }
        }

        events.sort { $0.0 < $1.0 }

        var intervals: [DateInterval] = []
        var pendingLock: Date? = nil
        var lastScreenOn: Date? = nil
        let minSleep: TimeInterval = 5 * 60

        for (date, evt) in events {
            switch evt {
            case "ScreenOn":
                lastScreenOn = date
            case "ScreenLocked":
                pendingLock = date
            case "ScreenUnlocked":
                var start: Date?
                if let lock = pendingLock {
                    start = lock
                } else if let on = lastScreenOn {
                    start = on
                }

                if let s = start, s < date {
                    let dur = date.timeIntervalSince(s)
                    if dur >= minSleep {
                        intervals.append(DateInterval(start: s, end: date))
                    }
                }

                pendingLock = nil
            default:
                break
            }
        }

        return intervals
    }

    // Stats
    private func computeStats(entries: [BatteryEntry], sleepIntervals: [DateInterval]) -> StatsSummary {
        guard let first = entries.first, let last = entries.last, last.timestamp > first.timestamp else {
            return StatsSummary(currentHealth: entries.last?.health,
                                currentCycles: entries.last?.cycles,
                                totalAwakeHours: 0,
                                avgHoursBetweenCharges: nil,
                                avgUsageHoursBetweenCharges: nil)
        }

        let range = DateInterval(start: first.timestamp, end: last.timestamp)
        let mergedSleeps = mergeIntervals(sleepIntervals)
        let totalAwakeSecs = awakeDuration(in: range, subtracting: mergedSleeps)

        let spans = betweenChargeSpans(using: entries)
        let avgBetweenHours: Double? = {
            guard !spans.isEmpty else { return nil }
            let s = spans.reduce(0.0) { $0 + $1.duration }
            return s / Double(spans.count) / 3600.0
        }()

        let avgUsageBetweenHours: Double? = {
            guard !spans.isEmpty else { return nil }
            let s = spans.reduce(0.0) { $0 + awakeDuration(in: $1, subtracting: mergedSleeps) }
            return s / Double(spans.count) / 3600.0
        }()

        return StatsSummary(
            currentHealth: entries.last?.health,
            currentCycles: entries.last?.cycles,
            totalAwakeHours: totalAwakeSecs / 3600.0,
            avgHoursBetweenCharges: avgBetweenHours,
            avgUsageHoursBetweenCharges: avgUsageBetweenHours
        )
    }

    private func betweenChargeSpans(using entries: [BatteryEntry]) -> [DateInterval] {
        guard entries.count >= 2 else { return [] }
        var starts: [Date] = []
        var ends: [Date] = []

        var prevAC = entries[0].ac
        for i in 1..<entries.count {
            let currAC = entries[i].ac
            if !prevAC && currAC {
                starts.append(entries[i].timestamp) // charge starts
            } else if prevAC && !currAC {
                ends.append(entries[i].timestamp)   // charge ends
            }
            prevAC = currAC
        }

        var spans: [DateInterval] = []
        var j = 0
        for end in ends {
            while j < starts.count && starts[j] <= end { j += 1 }
            if j < starts.count {
                spans.append(DateInterval(start: end, end: starts[j]))
            } else {
                break
            }
        }
        return spans
    }

    private func mergeIntervals(_ intervals: [DateInterval]) -> [DateInterval] {
        guard !intervals.isEmpty else { return [] }
        let sorted = intervals.sorted { $0.start < $1.start }
        var result: [DateInterval] = [sorted[0]]
        for iv in sorted.dropFirst() {
            if let last = result.last, last.end >= iv.start {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, iv.end))
            } else {
                result.append(iv)
            }
        }
        return result
    }

    private func overlap(_ a: DateInterval, _ b: DateInterval) -> TimeInterval {
        let s = max(a.start, b.start)
        let e = min(a.end, b.end)
        return max(0, e.timeIntervalSince(s))
    }

    private func awakeDuration(in range: DateInterval, subtracting sleeps: [DateInterval]) -> TimeInterval {
        var asleep: TimeInterval = 0
        for s in sleeps {
            asleep += overlap(range, s)
        }
        return max(0, range.duration - asleep)
    }
}

struct StatsSummary {
    var currentHealth: Double?
    var currentCycles: Int?
    var totalAwakeHours: Double
    var avgHoursBetweenCharges: Double?
    var avgUsageHoursBetweenCharges: Double?
}

struct StatBox: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.gray.opacity(0.12))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.35), lineWidth: 1))
        .cornerRadius(8)
    }
}

struct StatsPanel: View {
    let stats: StatsSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StatBox(
                    title: "Battery Health",
                    value: stats.currentHealth.map { String(format: "%.0f%%", $0) } ?? "—"
                )
                .frame(maxWidth: .infinity)

                StatBox(
                    title: "Charge Cycles",
                    value: stats.currentCycles.map(String.init) ?? "—"
                )
                .frame(maxWidth: .infinity)
            }

            StatBox(
                title: "Total Usage",
                value: String(format: "%.1f Hours", stats.totalAwakeHours)
            )
            .frame(maxWidth: .infinity)

            HStack(spacing: 10) {
                StatBox(
                    title: "Duration between Charges",
                    value: stats.avgHoursBetweenCharges.map { String(format: "%.1f Hours", $0) } ?? "—"
                )
                .frame(maxWidth: .infinity)

                StatBox(
                    title: "Usage between Charges",
                    value: stats.avgUsageHoursBetweenCharges.map { String(format: "%.1f Hours", $0) } ?? "—"
                )
                .frame(maxWidth: .infinity)
            }

            Spacer()
        }
        .padding(.trailing)
    }
}

struct BatteryEntry: Identifiable {
    var id = UUID()
    var timestamp: Date
    var charge: Double
    var health: Double? = nil
    var cycles: Int? = nil
    var ac: Bool = false
}

struct BatteryRect: Identifiable {
    var id = UUID()
    var start: Date
    var end: Date
    var charge: Double
    var asleep: Bool
}

enum Granularity {
    case fiveMin
    case hour
}

struct BatteryGraphView: View {
    let data: [BatteryEntry]
    let sleepIntervals: [DateInterval]
    @State private var granularity: Granularity = .fiveMin

    private let yTickValues: [Int] = [100, 75, 50, 25, 0]

    var body: some View {
        VStack(alignment: .leading) {
            Picker("", selection: $granularity) {
                Text("5 Minutes").tag(Granularity.fiveMin)
                Text("1 Hour").tag(Granularity.hour)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            HStack(spacing: 0) {
                FixedYAxis(ticks: yTickValues, topInset: 1, bottomInset: 36)
                    .padding(.leading, -4)
                    .frame(width: 40)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            chartView(for: granularity)
                                .frame(width: chartWidth(for: granularity))
                                .padding(.bottom, 18)

                            Color.clear
                                .frame(width: 1, height: 1)
                                .id("end")
                        }
                    }
                    .onAppear {
                        proxy.scrollTo("end", anchor: .trailing)
                    }
                    .onChange(of: granularity) {
                        proxy.scrollTo("end", anchor: .trailing)
                    }
                    .onChange(of: data.last?.timestamp) {
                        proxy.scrollTo("end", anchor: .trailing)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func chartView(for granularity: Granularity) -> some View {
        let rects = rectSeries(for: granularity)

        Chart {
            ForEach(yTickValues, id: \.self) { v in
                RuleMark(y: .value("Y", Double(v)))
                    .foregroundStyle(.secondary.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
            }

            ForEach(rects) { r in
                RectangleMark(
                    xStart: .value("Start", r.start),
                    xEnd: .value("End", r.end),
                    yStart: .value("Zero", 0.0),
                    yEnd: .value("Charge", r.charge)
                )
                .foregroundStyle(r.asleep ? Color.gray.opacity(0.8) : Color.blue.opacity(0.8))
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis(.hidden)
        .chartXAxis {
            switch granularity {
            case .fiveMin:
                AxisMarks(values: .stride(by: .hour, count: 1)) { value in
                    AxisTick()
                    if let date = value.as(Date.self) {
                        let hour = Calendar.current.component(.hour, from: date)
                        if hour == 0 {
                            AxisValueLabel {
                                Text(date, format: .dateTime.month(.abbreviated).day())
                                    .fontWeight(.bold)
                                    .foregroundStyle(.black)
                            }
                        } else {
                            AxisValueLabel {
                                Text(date, format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
                            }
                        }
                    }
                }
            case .hour:
                AxisMarks(values: .stride(by: .day, count: 1)) { value in
                    AxisTick()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: .dateTime.month(.abbreviated).day())
                                .fontWeight(.bold)
                                .foregroundStyle(.black)
                        }
                    }
                }
            }
        }
        .chartPlotStyle { plotArea in
            plotArea
                .padding(.top, 0)
                .padding(.trailing, 0)
                .clipped()
        }
    }

    private func chartWidth(for granularity: Granularity) -> CGFloat {
        guard let first = data.first?.timestamp,
              let last = data.last?.timestamp,
              last > first else {
            return 1000
        }

        let stepSeconds: Double = (granularity == .fiveMin) ? 5 * 60 : 60 * 60
        let bars = max(1, Int(ceil(last.timeIntervalSince(first) / stepSeconds)) + 1)

        let pxPerBar: CGFloat = 5.0
        return CGFloat(bars) * pxPerBar
    }

    private func rectSeries(for granularity: Granularity) -> [BatteryRect] {
        switch granularity {
        case .fiveMin:
            return rectangles(
                from: resample(entries: data, intervalMinutes: 5),
                intervalMinutes: 5,
                gapMinutes: 1
            )
        case .hour:
            return rectangles(
                from: resample(entries: data, intervalMinutes: 60),
                intervalMinutes: 60,
                gapMinutes: 10
            )
        }
    }

    private func rectangles(from entries: [BatteryEntry],
                            intervalMinutes: Int,
                            gapMinutes: Int) -> [BatteryRect] {
        let full = Double(intervalMinutes * 60)
        let gap = Double(gapMinutes * 60)
        let bar = max(0, full - gap)

        return entries.map { e in
            let start = e.timestamp
            let end = e.timestamp.addingTimeInterval(bar)
            let asleep = isAsleep(from: start, to: end)
            return BatteryRect(start: start,
                               end: end,
                               charge: max(0, min(100, e.charge)),
                               asleep: asleep)
        }
    }

    private func resample(entries: [BatteryEntry], intervalMinutes: Int) -> [BatteryEntry] {
        guard entries.count > 1,
              let first = entries.first,
              let last = entries.last else { return entries }

        var result: [BatteryEntry] = []
        let step = Double(intervalMinutes * 60)
        var t = first.timestamp
        let end = last.timestamp

        while t <= end {
            if let lower = entries.last(where: { $0.timestamp <= t }),
               let upper = entries.first(where: { $0.timestamp >= t }) {
                let frac = upper.timestamp == lower.timestamp ? 0 :
                    t.timeIntervalSince(lower.timestamp) / upper.timestamp.timeIntervalSince(lower.timestamp)
                let y = lower.charge + frac * (upper.charge - lower.charge)
                result.append(BatteryEntry(timestamp: t, charge: max(0, min(100, y))))
            }
            t.addTimeInterval(step)
        }
        return result
    }

    // asleep only if a sleep interval fully contains the bar
    private func isAsleep(from start: Date, to end: Date) -> Bool {
        guard end > start else { return false }
        for interval in sleepIntervals {
            if interval.start <= start && interval.end >= end {
                return true
            }
        }
        return false
    }
}

struct FixedYAxis: View {
    let ticks: [Int]
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 28

    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                let h = geo.size.height
                let plotH = max(1, h - topInset - bottomInset)

                ForEach(ticks, id: \.self) { v in
                    let y = topInset + plotH * (1 - CGFloat(v) / 100)

                    Path { p in
                        p.move(to: CGPoint(x: 28, y: y))
                        p.addLine(to: CGPoint(x: 34, y: y))
                    }
                    .stroke(.secondary.opacity(0.6), lineWidth: 1)

                    Text("\(v)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .position(x: 16, y: y)
                }
            }
        }
    }
}
