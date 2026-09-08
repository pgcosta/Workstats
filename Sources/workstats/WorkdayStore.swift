import Foundation

/// One workday's logon/logoff record. Times are local wall-clock; `date` is
/// start-of-day and acts as the row key (one row per day).
struct Workday: Codable, Identifiable, Equatable {
    var id: Date { date }
    var date: Date // start of day
    var start: Date?
    var end: Date?
}

/// Clock-in/out history, persisted at `~/Documents/workstats_days.csv`
/// (separate file so the check-in CSV schema never breaks).
///
/// Schema: `date,start_iso,end_iso` — date is `yyyy-MM-dd` local,
/// start/end are ISO8601 (empty when unset). One row per day; Start keeps
/// the earliest time, End keeps the latest.
final class WorkdayStore: ObservableObject {
    static let fileURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/workstats_days.csv")
    }()

    static var csvHeader: String { "date,start_iso,end_iso" }

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
        if let e = d.end {
            d.end = max(e, date)
        } else {
            d.end = date
        }
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
            lines.append("\(dayFmt.string(from: d.date)),\(iso(d.start)),\(iso(d.end))")
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
            out.append(Workday(date: date, start: start, end: end))
        }
        return out.sorted { $0.date < $1.date }
    }
}
