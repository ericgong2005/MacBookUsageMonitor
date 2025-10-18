import SwiftUI
import AppKit
import Charts

@main
struct UsageMonitorViewerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 710)
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
        let sleeps = parseSleepIntervals(from: screenLogs) // keeps ALL sleeps now
        let stats = computeStats(entries: entries, sleepIntervals: sleeps)
        let keyCounts = parseKeyFrequencyJSON(from: keyFrequency)
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
                    .padding(.top, 8)
                
                Text("Keyboard Usage Statistics")
                    .font(.title)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)

                // Keyboard heatmap (logarithmic color scale)
                VStack(alignment: .center) {
                    KeyboardHeatmapView(keyCounts: keyCounts)
                }
                .padding(.horizontal)
                .padding(.bottom, 12)

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
    // use the most recent ScreenOn as the sleep start. Ignore ScriptStarted. Do NOT drop short sleeps.
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

        for (date, evt) in events {
            switch evt {
            case "ScreenOn":
                lastScreenOn = date
            case "ScreenLocked":
                pendingLock = date
            case "ScreenUnlocked":
                let start: Date? = pendingLock ?? lastScreenOn
                if let s = start, s <= date {
                    // Keep every sleep interval, no matter how short (including zero-length)
                    intervals.append(DateInterval(start: s, end: date))
                }
                pendingLock = nil
            default:
                break
            }
        }

        return intervals
    }

    // Parse key_frequency.json into [String: Int]
    private func parseKeyFrequencyJSON(from text: String) -> [String: Int] {
        guard let data = text.data(using: .utf8) else { return [:] }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }

        var out: [String: Int] = [:]
        for (k, v) in raw {
            if let i = v as? Int {
                out[k] = i
            } else if let d = v as? Double {
                out[k] = Int(d.rounded())
            } else if let s = v as? String, let i = Int(s) {
                out[k] = i
            }
        }
        return out
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

// MARK: - Stats Views / Types

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

// MARK: - Battery Graph

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
            t = t.addingTimeInterval(step) // fix: Date is immutable; use returning API
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

// MARK: - Fixed Y Axis

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

// MARK: - Keyboard Heatmap

// ---------- Legends & Key model ----------

enum Legend { case text(String); case symbol(String) }

struct KeyLegends {
    var topLeft: Legend? = nil
    var topCenter: Legend? = nil
    var topRight: Legend? = nil
    var center: Legend? = nil
    var bottomLeft: Legend? = nil
    var bottomCenter: Legend? = nil
    var bottomRight: Legend? = nil
}

enum KeyShape { case rect, rectWithInnerCircle, arrowsCluster }
enum KeyFaceStyle { case single, numberDual, dualEqual } // numbers bigger on bottom for .numberDual

struct KeySpec: Identifiable {
    let id: String
    let width: CGFloat              // 1u = letter key
    let shape: KeyShape
    let legends: KeyLegends
    let synonyms: [String]
    let centered: Bool              // false = left-aligned label (tab/shift/etc.)
    let face: KeyFaceStyle
    let isFunctionKey: Bool

    init(_ id: String,
         width: CGFloat = 1.0,
         shape: KeyShape = .rect,
         legends: KeyLegends = KeyLegends(),
         synonyms: [String] = [],
         centered: Bool = true,
         face: KeyFaceStyle = .single,
         isFunctionKey: Bool = false) {
        self.id = id
        self.width = width
        self.shape = shape
        self.legends = legends
        self.synonyms = [id] + synonyms
        self.centered = centered
        self.face = face
        self.isFunctionKey = isFunctionKey
    }
}

// ---------- Layout (ANSI MBP proportions) ----------

private let keyHeight: CGFloat = 44      // ALL rows same height (Fn row too)
private let gap: CGFloat = 8
private let unit: CGFloat = 46           // 1u width

// Builders
private func num(_ n: String, _ shifted: String) -> KeySpec {
    // top & bottom centered; bottom (number) a bit larger
    KeySpec("Digit\(n)",
            legends: .init(topCenter: .text(shifted), bottomCenter: .text(n)),
            face: .numberDual)
}
private func punct(_ id: String, _ top: String, _ bottom: String, syn: [String] = []) -> KeySpec {
    // top & bottom centered; same size
    KeySpec(id,
            legends: .init(topCenter: .text(top), bottomCenter: .text(bottom)),
            synonyms: syn,
            face: .dualEqual)
}
private func txt(_ id: String, _ label: String, w: CGFloat = 1.0, syn: [String] = [], centered: Bool = true) -> KeySpec {
    KeySpec(id, width: w, legends: .init(center: .text(label)), synonyms: syn, centered: centered, face: .single)
}
private func fn(_ n: Int, _ symbol: String) -> KeySpec {
    // small symbol near top + F# centered at bottom
    KeySpec("F\(n)",
            legends: .init(topCenter: .symbol(symbol), bottomCenter: .text("F\(n)")),
            synonyms: ["f\(n)","F\(n)"],
            centered: true,
            face: .dualEqual,
            isFunctionKey: true)
}

// ---------- Rows ----------

private let keyboardRows: [[KeySpec]] = [
    // Row 0: Esc, F1..F12, Touch ID (square with circle)
    [
        txt("Esc", "esc", w: 1.5),
        fn(1,  "sun.min.fill"),
        fn(2,  "sun.max.fill"),
        fn(3,  "rectangle.3.group"),
        fn(4,  "magnifyingglass"),
        fn(5,  "mic.fill"),
        fn(6,  "moon.fill"),
        fn(7,  "backward.fill"),
        fn(8,  "playpause.fill"),
        fn(9,  "forward.fill"),
        fn(10, "speaker.slash.fill"),
        fn(11, "speaker.wave.1.fill"),
        fn(12, "speaker.wave.2.fill"),
        KeySpec("TouchID",
                width: 1.25,
                shape: .rectWithInnerCircle,
                legends: .init(),
                synonyms: ["power","touchid","lock"],
                centered: true)
    ],
    // Row 1: ` 1..0 - = delete
    [
        punct("Backtick", "~", "`", syn: ["backtick","grave"]),
        num("1","!"), num("2","@"), num("3","#"), num("4","$"), num("5","%"), num("6","^"),
        num("7","&"), num("8","*"), num("9","("), num("0",")"),
        punct("Minus", "_", "-", syn: ["minus","-","_"]),
        punct("Equal", "+", "="),
        txt("Delete", "delete", w: 1.75, syn: ["backspace"], centered: false)
    ],
    // Row 2: tab Q .. P [ ] \
    [
        txt("Tab", "tab", w: 1.7, centered: false),
        txt("KeyQ", "Q"), txt("KeyW", "W"), txt("KeyE", "E"), txt("KeyR", "R"),
        txt("KeyT", "T"), txt("KeyY", "Y"), txt("KeyU", "U"), txt("KeyI", "I"),
        txt("KeyO", "O"), txt("KeyP", "P"),
        punct("BracketLeft",  "{", "["),
        punct("BracketRight", "}", "]"),
        punct("Backslash", "|", "\\", syn: ["backslash"])
    ],
    // Row 3: caps A..' return
    [
        txt("CapsLock", "caps", w: 1.9, syn: ["capslock"], centered: false),
        txt("KeyA", "A"), txt("KeyS", "S"), txt("KeyD", "D"), txt("KeyF", "F"),
        txt("KeyG", "G"), txt("KeyH", "H"), txt("KeyJ", "J"), txt("KeyK", "K"), txt("KeyL", "L"),
        punct("Semicolon", ":", ";"),
        punct("Quote", "\"", "'"),
        txt("Return", "return", w: 2, syn: ["enter"], centered: false)
    ],
    // Row 4: shift Z.. / shift
    [
        txt("ShiftL", "shift", w: 2.5, syn: ["left shift"], centered: false),
        txt("KeyZ", "Z"), txt("KeyX", "X"), txt("KeyC", "C"), txt("KeyV", "V"),
        txt("KeyB", "B"), txt("KeyN", "N"), txt("KeyM", "M"),
        punct("Comma",  "<", ","),
        punct("Period", ">", "."),
        punct("Slash",  "?", "/"),
        txt("ShiftR", "shift", w: 2.5, syn: ["right shift"], centered: false)
    ],
    // Row 5: fn control option command SPACE command option + arrows
    [
        // fn: "fn" top-right, globe bottom-left
        KeySpec("Fn",
                legends: .init(topRight: .text("fn"), bottomLeft: .symbol("globe")),
                synonyms: ["function","fn"],
                centered: false),
        // Left modifiers: symbol top-right, word bottom-left
        KeySpec("Control",
                legends: .init(topRight: .text("⌃"), bottomLeft: .text("control")),
                synonyms: ["ctrl","control"],
                centered: false),
        KeySpec("OptionL",
                legends: .init(topRight: .text("⌥"), bottomLeft: .text("option")),
                synonyms: ["alt","option"],
                centered: false),
        KeySpec("CommandL", width: 1.3,
                legends: .init(topRight: .text("⌘"), bottomLeft: .text("command")),
                synonyms: ["cmd","command"],
                centered: false),
        txt("Space", "space", w: 5.75, syn: ["spacebar"," "], centered: true),
        // Right modifiers: symbol top-left, word bottom-right
        KeySpec("CommandR", width: 1.3,
                legends: .init(topLeft: .text("⌘"), bottomLeft: .text("command")),
                synonyms: ["cmd","command"],
                centered: false),
        KeySpec("OptionR",
                legends: .init(topLeft: .text("⌥"), bottomLeft: .text("option")),
                synonyms: ["alt","option"],
                centered: false),
        // Inverted-T with triangle glyphs
        KeySpec("ArrowCluster", width: 3.5, shape: .arrowsCluster)
    ]
]

// ---------- Heat coloring (log scale) ----------

// Gradient (purple → blue → green → yellow → red). Zero-count handled separately.
private struct ColorStop { let t: CGFloat; let color: NSColor }
private let heatStops: [ColorStop] = [
    .init(t: 0.00, color: .systemPurple),
    .init(t: 0.25, color: .systemBlue),
    .init(t: 0.50, color: .systemGreen),
    .init(t: 0.75, color: .systemYellow),
    .init(t: 1.00, color: .systemRed)
]

private func interpolateColor(_ stops: [ColorStop], t raw: CGFloat) -> Color {
    let t = max(0, min(1, raw))
    guard let hi = stops.firstIndex(where: { t <= $0.t }), hi > 0 else {
        return Color(stops.last?.color ?? .systemGray)
    }
    let lo = hi - 1
    let a = stops[lo], b = stops[hi]
    let u = (t - a.t) / max(0.0001, b.t - a.t)
    func comps(_ c: NSColor) -> (CGFloat,CGFloat,CGFloat,CGFloat) {
        let s = c.usingColorSpace(.sRGB) ?? c
        return (s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent)
    }
    let (r1,g1,b1,a1) = comps(a.color)
    let (r2,g2,b2,a2) = comps(b.color)
    return Color(NSColor(srgbRed: r1 + (r2-r1)*u,
                         green:  g1 + (g2-g1)*u,
                         blue:   b1 + (b2-b1)*u,
                         alpha:  a1 + (a2-a1)*u))
}

// Color helper: grey for zero, otherwise log-mapped into the gradient above.
private func colorFor(count: Int, maxCount: Int) -> Color {
    if count <= 0 { return Color(NSColor.systemGray) }
    let t = CGFloat(log1p(Double(count)) / log1p(Double(max(1, maxCount))))
    return interpolateColor(heatStops, t: t)
}

// ---------- JSON → Graphic-key mapping (YOU can edit this) ----------
// Keys are matched case-insensitively after removing spaces, "_" and "-".
// Values must be the graphic IDs used in this file (e.g. "KeyA", "Digit1", "Return", "OptionR", "F1", "Left", "TouchID", ...)

let JSON_KEY_TO_GRAPH_ID: [String: String] = [
    // Letters
    "0": "KeyA", "11": "KeyB", "8": "KeyC", "2": "KeyD", "14": "KeyE", "3": "KeyF",
    "5": "KeyG", "4": "KeyH", "34": "KeyI", "38": "KeyJ", "40": "KeyK", "37": "KeyL",
    "46": "KeyM", "45": "KeyN", "31": "KeyO", "35": "KeyP", "12": "KeyQ", "15": "KeyR",
    "1": "KeyS", "17": "KeyT", "32": "KeyU", "9": "KeyV", "13": "KeyW", "7": "KeyX",
    "16": "KeyY", "6": "KeyZ",

    // Digits & shifted (map either one)
    "18": "Digit1", "!": "Digit1",
    "19": "Digit2", "@": "Digit2",
    "20": "Digit3", "#": "Digit3",
    "21": "Digit4", "$": "Digit4",
    "23": "Digit5", "%": "Digit5",
    "22": "Digit6", "^": "Digit6",
    "26": "Digit7", "&": "Digit7",
    "28": "Digit8", "*": "Digit8",
    "25": "Digit9", "(": "Digit9",
    "29": "Digit0", ")": "Digit0",

    // Punctuation
    "50": "Backtick", "~": "Backtick",
    "27": "Minus", "_": "Minus",
    "24": "Equal", "+": "Equal",
    "33": "BracketLeft", "{": "BracketLeft",
    "30": "BracketRight", "}": "BracketRight",
    "42": "Backslash", "|": "Backslash",
    "41": "Semicolon", ":": "Semicolon",
    "39": "Quote", "\"": "Quote",
    "43": "Comma", "<": "Comma",
    "47": "Period", ">": "Period",
    "44": "Slash", "?": "Slash",

    // Function row
    "53": "Esc", "escape": "Esc",
    "f1": "F1", "f2": "F2", "160": "F3", "177": "F4", "176": "F5", "178": "F6",
    "f7": "F7", "f8": "F8", "f9": "F9", "f10": "F10", "f11": "F11", "f12": "F12",
    "touchid": "TouchID", "power": "TouchID",

    // Modifiers (choose left/right if your JSON distinguishes them)
    "48": "Tab",
    "57": "CapsLock",
    "56": "ShiftL", "60": "ShiftR",
    "59": "Control",
    "58": "OptionL", "61": "OptionR",
    "55": "CommandL", "54": "CommandR",
    "63": "Fn",
    "36": "Return",
    "51": "Delete",
    "49": "Space",

    // Arrows
    "123": "Left",
    "124": "Right",
    "126": "Up",
    "125": "Down"
]

// Normalization used for matching (lowercased; remove spaces, "_" and "-")
@inline(__always)
func normalizeKeyName(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
     .lowercased()
     .replacingOccurrences(of: " ", with: "")
     .replacingOccurrences(of: "_", with: "")
     .replacingOccurrences(of: "-", with: "")
}

// Pre-normalized lookup so you don't have to normalize when filling the dict above.
let JSON_KEY_TO_GRAPH_ID_NORM: [String: String] = {
    var out: [String: String] = [:]
    for (k, v) in JSON_KEY_TO_GRAPH_ID { out[normalizeKeyName(k)] = v }
    return out
}()

// ---------- Heatmap view ----------

struct KeyboardHeatmapView: View {
    let keyCounts: [String: Int]

    // Use your mapping first; fall back to original tokens for synonym/label heuristics
    private var sourceCounts: [String: Int] {
        var agg: [String: Int] = [:]
        for (rawKey, val) in keyCounts {
            let norm = normalizeKeyName(rawKey)
            if let id = JSON_KEY_TO_GRAPH_ID_NORM[norm] {
                // store by normalized graphic ID (e.g., "keya", "digit1", "return")
                agg[normalizeKeyName(id), default: 0] += val
            } else {
                // keep the normalized raw token so existing synonyms/labels can still match it
                agg[norm, default: 0] += val
            }
        }
        return agg
    }

    // Helper to read a count by any name (we always normalize the lookup)
    private func countFor(_ name: String) -> Int {
        sourceCounts[normalizeKeyName(name)] ?? 0
    }

    private var totals: [String: Int] {
        var out: [String: Int] = [:]

        func addToID(_ id: String, names: [String], label: String?) {
            var s = 0
            for n in names { s += countFor(n) }
            if let l = label { s += countFor(l) }
            if id == "Space" { s += countFor(" ") }
            out[id, default: 0] += s
        }

        for row in keyboardRows {
            for k in row {
                switch k.shape {
                case .arrowsCluster:
                    addToID("Left",  names: ["Left","arrowleft","←","◀"], label: nil)
                    addToID("Right", names: ["Right","arrowright","→","▶"], label: nil)
                    addToID("Up",    names: ["Up","arrowup","↑","▲"],     label: nil)
                    addToID("Down",  names: ["Down","arrowdown","↓","▼"], label: nil)
                default:
                    let label: String? = {
                        if case .text(let t) = k.legends.center, t.count == 1 { return t }
                        return nil
                    }()
                    // `k.synonyms` already includes `k.id`
                    addToID(k.id, names: k.synonyms, label: label)
                }
            }
        }
        return out
    }
    
    private func colorForID(_ id: String) -> Color {
        colorFor(count: totals[id] ?? 0, maxCount: maxCount)
    }

    private var maxCount: Int { max(1, totals.values.max() ?? 1) }
    private func t(_ id: String) -> CGFloat {
        let c = totals[id] ?? 0
        return CGFloat(log1p(Double(c)) / log1p(Double(maxCount)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                LogLegendView(raw: keyCounts).frame(width: 240, height: 22)
            }

            VStack(alignment: .leading, spacing: gap) {
                ForEach(0..<keyboardRows.count, id: \.self) { _row in
                    let row = keyboardRows[_row]
                    HStack(spacing: gap) {
                        ForEach(row) { key in
                            switch key.shape {
                            case .rectWithInnerCircle:
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(colorForID(key.id))   // was: interpolateColor(heatStops, t: t(key.id))
                                    .frame(width: key.width * unit, height: keyHeight)
                                    .overlay(
                                        Circle().strokeBorder(Color.primary.opacity(0.85), lineWidth: 2).padding(7)
                                    )
                            case .arrowsCluster:
                                ArrowClusterView(
                                    width: key.width * unit,
                                    height: keyHeight,
                                    colorLeft:  colorForID("Left"),
                                    colorDown:  colorForID("Down"),
                                    colorRight: colorForID("Right"),
                                    colorUp:    colorForID("Up")
                                )
                            case .rect:
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(colorForID(key.id))
                                    .frame(width: key.width * unit, height: keyHeight)
                                    .overlay(
                                        KeyLegendsView(legends: key.legends,
                                                       centered: key.centered,
                                                       face: key.face,
                                                       isFnKey: key.isFunctionKey)
                                    )
                                    .accessibilityLabel("\(key.id): \(totals[key.id] ?? 0) presses")
                            }
                        }
                    }
                }
            }
        }
    }
}

// ---------- Legends renderer (smaller everywhere) ----------

private struct KeyLegendsView: View {
    let legends: KeyLegends
    let centered: Bool
    let face: KeyFaceStyle
    let isFnKey: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            // Global smaller sizes
            let small: CGFloat = min(11, h * 0.26)         // small corners / top/bottom text
            let smallFn: CGFloat = min(10, h * 0.23)       // Fn row icon
            let numberBottom: CGFloat = min(13, h * 0.30)  // slightly bigger for numbers
            let centerText: CGFloat = centered ? min(13, h * 0.30) : min(11, h * 0.26)

            let pad: CGFloat = 6
            let topPad: CGFloat = isFnKey ? 3 : 6          // Fn symbols closer to top

            ZStack {
                // Top-left / top-right (symbols on modifiers; tiny)
                if let tl = legends.topLeft {
                    HStack { legendView(tl).font(.system(size: small, weight: .semibold)); Spacer() }
                        .frame(width: w, height: h, alignment: .topLeading)
                        .padding(.top, topPad).padding(.leading, pad)
                }
                if let tr = legends.topRight {
                    HStack { Spacer(); legendView(tr).font(.system(size: small, weight: .semibold)) }
                        .frame(width: w, height: h, alignment: .topTrailing)
                        .padding(.top, topPad).padding(.trailing, pad)
                }

                // Top-center
                if let tc = legends.topCenter {
                    VStack { legendView(tc).font(.system(size: isFnKey ? smallFn : small, weight: .semibold)); Spacer() }
                        .frame(width: w, height: h, alignment: .top)
                        .padding(.top, topPad)
                }

                // Center (single-face)
                if let c = legends.center {
                    HStack {
                        if centered { Spacer() }
                        legendView(c).font(.system(size: centerText, weight: .semibold))
                        if centered { Spacer() }
                    }
                    .frame(width: w, height: h, alignment: centered ? .center : .leading)
                    .padding(.leading, centered ? 0 : pad)
                }

                // Bottom-left / bottom-right (words on modifiers)
                if let bl = legends.bottomLeft {
                    HStack { legendView(bl).font(.system(size: small, weight: .regular)); Spacer() }
                        .frame(width: w, height: h, alignment: .bottomLeading)
                        .padding(.bottom, pad).padding(.leading, pad)
                }
                if let br = legends.bottomRight {
                    HStack { Spacer(); legendView(br).font(.system(size: small, weight: .regular)) }
                        .frame(width: w, height: h, alignment: .bottomTrailing)
                        .padding(.bottom, pad).padding(.trailing, pad)
                }

                // Bottom-center (dual faces)
                if let bc = legends.bottomCenter {
                    let size: CGFloat = {
                        switch face {
                        case .numberDual: return numberBottom
                        case .dualEqual:  return small
                        case .single:     return centerText
                        }
                    }()
                    VStack { Spacer(); legendView(bc).font(.system(size: size, weight: .semibold)) }
                        .frame(width: w, height: h, alignment: .bottom)
                        .padding(.bottom, pad)
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func legendView(_ l: Legend) -> some View {
        switch l {
        case .text(let s): Text(s)
        case .symbol(let s): Image(systemName: s)
        }
    }
}

// ---------- Inverted-T arrows (tight ▲ ▼ with no gap) ----------

private struct ArrowClusterView: View {
    let width: CGFloat
    let height: CGFloat
    let colorLeft: Color
    let colorDown: Color
    let colorRight: Color
    let colorUp: Color

    var body: some View {
        let gap: CGFloat = 8
        let unit: CGFloat = 46
        let halfH = height / 2    // no gap between ▲/▼

        ZStack(alignment: .leading) {
            // Left (◀)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(colorLeft)
                .frame(width: unit, height: halfH)
                .overlay(Text("◀").font(.system(size: 12, weight: .semibold)))
                .offset(x: -unit-gap, y: halfH/2)

            // Up / Down (touching)
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(colorUp)
                    .frame(width: unit, height: halfH)
                    .overlay(Text("▲").font(.system(size: 11, weight: .semibold)))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(colorDown)
                    .frame(width: unit, height: halfH)
                    .overlay(Text("▼").font(.system(size: 11, weight: .semibold)))
            }
            .frame(width: unit, height: height)

            // Right (▶)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(colorRight)
                .frame(width: unit, height: halfH)
                .overlay(Text("▶").font(.system(size: 12, weight: .semibold)))
                .offset(x: unit + gap, y: halfH/2)
        }
        .frame(width: width, height: height)
    }
}

// ---------- Log legend ----------

struct LogLegendView: View {
    let raw: [String: Int]
    var body: some View {
        let maxCount = max(1, raw.values.max() ?? 1)
        let ticks: [Int] = [
            0,
            max(1, Int(pow(10.0, log10(Double(maxCount)) * 0.33))),
            max(1, Int(pow(10.0, log10(Double(maxCount)) * 0.66))),
            maxCount
        ]
        HStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    LinearGradient(
                        gradient: Gradient(colors: stride(from: 0.0, through: 1.0, by: 0.05).map { t in
                            interpolateColor(heatStops, t: t)
                        }),
                        startPoint: .leading, endPoint: .trailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    ForEach(0..<ticks.count, id: \.self) { i in
                        let v = Double(ticks[i])
                        let t = CGFloat(log1p(v)/log1p(Double(maxCount)))
                        Rectangle()
                            .fill(Color.primary.opacity(0.7))
                            .frame(width: 1, height: 10)
                            .position(x: t * w, y: geo.size.height/2)
                    }
                }
            }
            .frame(height: 10)

            HStack(spacing: 6) {
                ForEach(ticks, id: \.self) { v in
                    Text("\(v)").font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
