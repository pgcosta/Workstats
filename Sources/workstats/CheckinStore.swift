import Foundation

/// Appends check-ins to ~/Documents/workstats.csv, creates header if needed.
final class CheckinStore: ObservableObject {
    static let fileURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/workstats.csv")
    }()

    @Published private(set) var todayCount: Int = 0

    init() {
        ensureFile()
        refreshTodayCount()
    }

    private func ensureFile() {
        let url = Self.fileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? (Checkin.csvHeader + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func append(_ checkin: Checkin) {
        ensureFile()
        let line = checkin.csvRow() + "\n"
        guard let handle = try? FileHandle(forWritingTo: Self.fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line.data(using: .utf8) ?? Data())
        refreshTodayCount()
    }

    func refreshTodayCount() {
        guard let text = try? String(contentsOf: Self.fileURL, encoding: .utf8) else {
            todayCount = 0
            return
        }
        let today = Calendar.current.startOfDay(for: Date())
        let lines = text.split(separator: "\n").dropFirst() // skip header
        var n = 0
        for line in lines {
            // timestamp is first field, ISO8601
            let ts = line.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
            if let d = ISO8601DateFormatter.shared.date(from: ts),
               Calendar.current.isDate(d, inSameDayAs: today) {
                n += 1
            } else if ts.prefix(10) == ISO8601DayFormatter.shared.string(from: today) {
                n += 1
            }
        }
        DispatchQueue.main.async { self.todayCount = n }
    }
}

private enum ISO8601DayFormatter {
    static let shared: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
}
