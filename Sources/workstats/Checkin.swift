import Foundation

enum ActivityMode: String, Codable, CaseIterable {
    case working
    case leisure
}

struct Checkin: Codable {
    var timestamp: Date
    var mode: ActivityMode
    /// 1-5, nil when leisure
    var focus: Int?
    var procrastination: Int?
    var accomplished: Int?
    var trigger: String // "random", "manual", "snoozed"

    func csvRow() -> String {
        let iso = ISO8601DateFormatter.shared.string(from: timestamp)
        func f(_ v: Int?) -> String { v.map(String.init) ?? "" }
        // Quote trigger defensively, no commas expected
        return "\(iso),\(mode.rawValue),\(f(focus)),\(f(procrastination)),\(f(accomplished)),\(trigger)"
    }

    static var csvHeader: String {
        "timestamp,mode,focus_depth_1_5,procrastination_1_5,accomplished_1_5,trigger"
    }
}

extension ISO8601DateFormatter {
    static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
