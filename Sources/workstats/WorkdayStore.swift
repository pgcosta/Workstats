import Foundation

/// One workday's logon/logoff record. Times are local wall-clock; `date` is
/// start-of-day and acts as the row key (one row per day).
struct Workday: Codable, Identifiable, Equatable {
    var id: Date { date }
    var date: Date // start of day
    var start: Date?
    var end: Date?
    /// Pauses inside the shift (bathroom, lunch, coffee…). Net active time =
    /// gross (end−start) minus these.
    var breaks: [WorkBreak] = []
}

/// A single pause. `resume == nil` means the break is still open.
struct WorkBreak: Codable, Equatable {
    var pause: Date
    var resume: Date?
}

/// Clock-in/out history, persisted at `~/Documents/workstats_days.csv`
/// (separate file so the check-in CSV schema never breaks).
///
/// Schema: `date,start_iso,end_iso,breaks` — date is `yyyy-MM-dd` local,
/// start/end are ISO8601 (empty when unset), breaks encode as
/// `pauseISO~resumeISO;…` (resume empty while the break is open).
/// Old 3-column rows still load (breaks = []). One row per day;
/// Start keeps the earliest time, End keeps the latest.
final class WorkdayStore: ObservableObject {
    static let fileURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/workstats_days.csv")
    }()

    static var csvHeader: String { "date,start_iso,end_iso,breaks" }

    @Published private(set) var days: [Workday] = []

    init() {
        reload()
    }

    // MARK: - Queries

    func day(for date: Date) -> Workday? {
        let key = Calendar.current.startOfDay(for: date)
        return days.first { Calendar.current.isDate($0.date, inSameDayAs: key) }
    }

    var today: Workday? { day(for: Date()) }

    /// Clocked in and not yet out.
    var isOpenToday: Bool {
        guard let t = today, t.start != nil else { return false }
        return t.end == nil
    }

    var hasEndedToday: Bool {
        today?.end != nil
    }

    /// Mid-shift pause still open (bathroom, lunch, coffee…).
    var isOnBreakToday: Bool {
        today?.breaks.contains { $0.resume == nil } ?? false
    }

    // MARK: - Active / break math (seconds)

    /// Gross wall-clock: start → end (or now while open). Past days with a
    /// missing clock-out are capped at midnight so a forgotten tap can't
    /// inflate history.
    func grossSeconds(_ day: Workday, at now: Date = Date()) -> Int {
        guard let s = day.start else { return 0 }
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: day.date) ?? now
        let e = min(day.end ?? now, midnight, now)
        return max(0, Int(e.timeIntervalSince(s)))
    }

    /// Time inside breaks, open break counted up to now (or clock-out).
    func breakSeconds(_ day: Workday, at now: Date = Date()) -> Int {
        let cap = min(day.end ?? now, now)
        return day.breaks.reduce(0) { acc, b in
            guard b.pause < cap else { return acc }
            let e = min(b.resume ?? now, cap)
            return acc + max(0, Int(e.timeIntervalSince(b.pause)))
        }
    }

    func activeSeconds(_ day: Workday, at now: Date = Date()) -> Int {
        max(0, grossSeconds(day, at: now) - breakSeconds(day, at: now))
    }

    /// Was this timestamp inside net active time (shift minus breaks)?
    /// Days with no clock-in record count as fully active (assume working).
    func isActive(_ timestamp: Date) -> Bool {
        guard let d = day(for: timestamp), let s = d.start else { return true }
        let e = d.end ?? .distantFuture
        guard timestamp >= s && timestamp <= e else { return false }
        return !d.breaks.contains { b in
            timestamp >= b.pause && timestamp <= (b.resume ?? .distantFuture)
        }
    }

    // MARK: - Mutations

    /// Clock in. Keeps the earliest start (second tap doesn't move it later).
    func startDay(at date: Date = Date()) {
        var d = day(for: date) ?? Workday(date: Calendar.current.startOfDay(for: date))
        if let s = d.start {
            d.start = min(s, date)
        } else {
            d.start = date
        }
        // Reopening clears a same-day end (user hit Start after End).
        if let e = d.end, e <= date {
            d.end = nil
        }
        upsert(d)
    }

    func endDay(at date: Date = Date()) {
        var d = day(for: date) ?? Workday(date: Calendar.current.startOfDay(for: date))
        if d.start == nil { d.start = date }
        // Clocking out mid-break closes the break at the same time.
        for i in d.breaks.indices where d.breaks[i].resume == nil {
            d.breaks[i].resume = date
        }
        if let e = d.end {
            d.end = max(e, date)
        } else {
            d.end = date
        }
        upsert(d)
    }

    /// Pause mid-shift (break starts now). No-op unless clocked in, not out,
    /// and not already on a break.
    func pauseToday(at date: Date = Date()) {
        guard var d = day(for: date),
              d.start != nil, d.end == nil,
              !d.breaks.contains(where: { $0.resume == nil }) else { return }
        d.breaks.append(WorkBreak(pause: date))
        upsert(d)
    }

    /// Back from a break (closes the open one now).
    func resumeToday(at date: Date = Date()) {
        guard var d = day(for: date) else { return }
        guard let i = d.breaks.lastIndex(where: { $0.resume == nil }) else { return }
        d.breaks[i].resume = date
        upsert(d)
    }

    /// Correct a logged time (the "started at 9 but logging at 9:20" case).
    func setStart(_ date: Date?, on day: Date = Date()) {
        var d = self.day(for: day) ?? Workday(date: Calendar.current.startOfDay(for: day))
        d.start = date
        upsert(d)
    }

    func setEnd(_ date: Date?, on day: Date = Date()) {
        var d = self.day(for: day) ?? Workday(date: Calendar.current.startOfDay(for: day))
        d.end = date
        upsert(d)
    }

    func reopenToday() {
        setEnd(nil)
    }

    // MARK: - Persistence

    func reload() {
        days = Self.load()
    }

    private func upsert(_ day: Workday) {
        if let i = days.firstIndex(where: { Calendar.current.isDate($0.date, inSameDayAs: day.date) }) {
            days[i] = day
        } else {
            days.append(day)
        }
        days.sort { $0.date < $1.date }
        save()
    }

    private func save() {
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        var lines = [Self.csvHeader]
        for d in days {
            let iso: (Date?) -> String = { $0.map { ISO8601DateFormatter.shared.string(from: $0) } ?? "" }
            let breaks = d.breaks.map { b in
                "\(ISO8601DateFormatter.shared.string(from: b.pause))~\(iso(b.resume))"
            }.joined(separator: ";")
            lines.append("\(dayFmt.string(from: d.date)),\(iso(d.start)),\(iso(d.end)),\(breaks)")
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: Self.fileURL, atomically: true, encoding: .utf8)
    }

    static func load() -> [Workday] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        var out: [Workday] = []
        for line in text.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 1, let date = dayFmt.date(from: parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let start = parts.count > 1 ? StatsEngine.parseDate(parts[1].trimmingCharacters(in: .whitespaces)) : nil
            let end = parts.count > 2 ? StatsEngine.parseDate(parts[2].trimmingCharacters(in: .whitespaces)) : nil
            var breaks: [WorkBreak] = []
            if parts.count > 3 {
                for item in parts[3].split(separator: ";") {
                    let ends = item.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
                    guard let pause = StatsEngine.parseDate(ends[0].trimmingCharacters(in: .whitespaces)) else { continue }
                    let resume = ends.count > 1 ? StatsEngine.parseDate(ends[1].trimmingCharacters(in: .whitespaces)) : nil
                    breaks.append(WorkBreak(pause: pause, resume: resume))
                }
            }
            out.append(Workday(date: date, start: start, end: end, breaks: breaks))
        }
        return out.sorted { $0.date < $1.date }
    }
}
