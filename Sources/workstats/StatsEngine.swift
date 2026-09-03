import Foundation

/// Parsing + aggregation for stats. Metrics come from working check-ins only;
/// leisure check-ins count toward volume/working-% but have no 1-5 values.
enum StatsEngine {
    // MARK: - Load

    static func load() -> [Checkin] {
        guard let text = try? String(contentsOf: CheckinStore.fileURL, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n").dropFirst()
        var out: [Checkin] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            // timestamp,mode,focus,procrast,accomp,trigger
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 6 else { continue }
            guard let date = parseDate(parts[0]) else { continue }
            guard let mode = ActivityMode(rawValue: parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let c = Checkin(
                timestamp: date,
                mode: mode,
                focus: Int(parts[2]),
                procrastination: Int(parts[3]),
                accomplished: Int(parts[4]),
                trigger: parts[5]
            )
            out.append(c)
        }
        return out.sorted { $0.timestamp < $1.timestamp }
    }

    static func parseDate(_ s: String) -> Date? {
        if let d = ISO8601DateFormatter.shared.date(from: s) { return d }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: s)
    }

    // MARK: - Models

    struct DayStat: Identifiable {
        var id: Date { day }
        var day: Date
        var label: String
        var focus: Double?
        var procrast: Double?
        var accomp: Double?
        var count: Int
        var workingCount: Int
        /// Composite 1-5: (focus + accomp + (6 - procrast)) / 3. Higher = better.
        var score: Double?
    }

    struct MetricPoint: Identifiable {
        var id: String { "\(day.timeIntervalSince1970)-\(metric)" }
        var day: Date
        var dayLabel: String
        var metric: String
        var value: Double
    }

    struct HourStat: Identifiable {
        var id: Int { hour }
        var hour: Int
        var label: String
        var focus: Double
        var count: Int
    }

    struct WeekdayStat: Identifiable {
        var id: Int { weekday }
        var weekday: Int // 1=Sun..7=Sat
        var name: String
        var focus: Double
        var count: Int
    }

    // MARK: - Aggregation

    static func daily(_ checkins: [Checkin]) -> [DayStat] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: checkins) { cal.startOfDay(for: $0.timestamp) }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE d MMM"
        return grouped.keys.sorted().map { day in
            let rows = grouped[day] ?? []
            let working = rows.filter { $0.mode == .working }
            func avg(_ kp: (Checkin) -> Int?) -> Double? {
                let vals = working.compactMap(kp)
                guard !vals.isEmpty else { return nil }
                return Double(vals.reduce(0, +)) / Double(vals.count)
            }
            let f = avg { $0.focus }
            let p = avg { $0.procrastination }
            let a = avg { $0.accomplished }
            var score: Double?
            if let f, let p, let a { score = (f + a + (6 - p)) / 3 }
            return DayStat(
                day: day, label: fmt.string(from: day),
                focus: f, procrast: p, accomp: a,
                count: rows.count, workingCount: working.count, score: score
            )
        }
    }

    static func metricPoints(_ days: [DayStat]) -> [MetricPoint] {
        var pts: [MetricPoint] = []
        for d in days {
            if let v = d.focus { pts.append(.init(day: d.day, dayLabel: d.label, metric: "🎯 Focus", value: v)) }
            if let v = d.procrast { pts.append(.init(day: d.day, dayLabel: d.label, metric: "🌀 Procrast.", value: v)) }
            if let v = d.accomp { pts.append(.init(day: d.day, dayLabel: d.label, metric: "🏆 Accompl.", value: v)) }
        }
        return pts
    }

    static func hourlyFocus(_ checkins: [Checkin]) -> [HourStat] {
        let cal = Calendar.current
        let working = checkins.filter { $0.mode == .working && $0.focus != nil }
        let grouped = Dictionary(grouping: working) { cal.component(.hour, from: $0.timestamp) }
        return grouped.keys.sorted().map { h in
            let vals = (grouped[h] ?? []).compactMap { $0.focus }
            let avg = Double(vals.reduce(0, +)) / Double(max(1, vals.count))
            return HourStat(hour: h, label: "\(h)h", focus: avg, count: vals.count)
        }
    }

    static func weekdayFocus(_ checkins: [Checkin]) -> [WeekdayStat] {
        let cal = Calendar.current
        let working = checkins.filter { $0.mode == .working && $0.focus != nil }
        let grouped = Dictionary(grouping: working) { cal.component(.weekday, from: $0.timestamp) }
        let names = cal.shortWeekdaySymbols // Sun..Sat
        return grouped.keys.sorted().map { w in
            let vals = (grouped[w] ?? []).compactMap { $0.focus }
            let avg = Double(vals.reduce(0, +)) / Double(max(1, vals.count))
            let name = w - 1 < names.count ? names[w - 1] : "d\(w)"
            return WeekdayStat(weekday: w, name: name, focus: avg, count: vals.count)
        }
    }

    // MARK: - Summary

    struct Summary {
        var total = 0
        var workingPct = 0.0
        var avgFocus = 0.0
        var avgProcrast = 0.0
        var avgAccomp = 0.0
        var avgScore = 0.0
        var bestDay: DayStat?
        var worstDay: DayStat?
        var bestHour: HourStat?
        var bestWeekday: WeekdayStat?
    }

    static func summary(checkins: [Checkin], days: [DayStat], hours: [HourStat], weekdays: [WeekdayStat]) -> Summary {
        var s = Summary()
        s.total = checkins.count
        if !checkins.isEmpty {
            s.workingPct = 100 * Double(checkins.filter { $0.mode == .working }.count) / Double(checkins.count)
        }
        let working = checkins.filter { $0.mode == .working }
        func avg(_ kp: (Checkin) -> Int?) -> Double {
            let v = working.compactMap(kp)
            guard !v.isEmpty else { return 0 }
            return Double(v.reduce(0, +)) / Double(v.count)
        }
        s.avgFocus = avg { $0.focus }
        s.avgProcrast = avg { $0.procrastination }
        s.avgAccomp = avg { $0.accomplished }
        let scored = days.filter { $0.score != nil }
        if !scored.isEmpty {
            s.avgScore = scored.compactMap { $0.score }.reduce(0, +) / Double(scored.count)
            s.bestDay = scored.max { ($0.score ?? 0) < ($1.score ?? 0) }
            s.worstDay = scored.min { ($0.score ?? 0) < ($1.score ?? 0) }
        }
        s.bestHour = hours.max { $0.focus < $1.focus }
        s.bestWeekday = weekdays.max { $0.focus < $1.focus }
        return s
    }

    // MARK: - Demo seed (so graphs visible before real data piles up)

    static func seedDemoData(days: Int = 14, store: CheckinStore) {
        let cal = Calendar.current
        var rng = SystemRandomNumberGenerator()
        for back in stride(from: days, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let wd = cal.component(.weekday, from: day)
            if wd == 1 || wd == 7 { continue }
            let n = Int.random(in: 3...6, using: &rng)
            for _ in 0..<n {
                let hour = Int.random(in: 9..<18, using: &rng)
                let minute = Int.random(in: 0..<60, using: &rng)
                var comps = cal.dateComponents([.year, .month, .day], from: day)
                comps.hour = hour; comps.minute = minute
                let ts = cal.date(from: comps) ?? day
                // Morning people: better focus 9-11, dip after lunch
                let base = (9...11).contains(hour) ? 4 : (hour == 13 ? 2 : 3)
                let jitter = Int.random(in: -1...1, using: &rng)
                let clamp = { (v: Int) in min(5, max(1, v)) }
                let mode: ActivityMode = Double.random(in: 0...1, using: &rng) < 0.8 ? .working : .leisure
                store.append(Checkin(
                    timestamp: ts, mode: mode,
                    focus: mode == .working ? clamp(base + jitter) : nil,
                    procrastination: mode == .working ? clamp(4 - base + jitter + 1) : nil,
                    accomplished: mode == .working ? clamp(base + Int.random(in: -1...1, using: &rng)) : nil,
                    trigger: "demo"
                ))
            }
        }
        store.refreshTodayCount()
    }
}
