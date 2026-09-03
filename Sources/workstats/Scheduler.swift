import Foundation
import AppKit
import UserNotifications
import Combine

/// Fires random prompts Mon-Fri 9:00-18:00.
/// Soft alerts: banner notification (silent) + system sound + menu-bar badge.
/// Never steals focus, never auto-opens windows; user checks in via dropdown.
/// Default window 10-30 min: app start -> first prompt in 10-30 min;
/// after every submitted check-in the clock restarts (-> next in 10-30 min).
/// Outside work hours: waits for next 9:00 weekday.
final class Scheduler: ObservableObject {
    @Published var nextCheck: Date?
    @Published var pausedToday = false
    @Published var notificationsOK = true // false when system notifications denied/ephemeral-off
    @Published var minMinutes: Double
    @Published var maxMinutes: Double

    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private let minKey = "workstats.minMinutes"
    private let maxKey = "workstats.maxMinutes"

    /// Friendly presets: (emoji, name, min, max)
    static let presets: [(String, String, Double, Double)] = [
        ("⚡️", "Quick", 5, 15),
        ("🌱", "Steady", 10, 30),
        ("☕️", "Relaxed", 20, 45),
        ("🧘", "Deep work", 30, 60),
    ]

    var onFire: ((String) -> Void)?

    init() {
        let savedMin = defaults.double(forKey: minKey)
        let savedMax = defaults.double(forKey: maxKey)
        self.minMinutes = savedMin >= 2 ? savedMin : 10
        self.maxMinutes = savedMax > savedMin ? savedMax : 30
        if self.maxMinutes <= self.minMinutes { self.maxMinutes = self.minMinutes + 10 }
        requestNotificationAuth()
        scheduleNext(reason: "init")
    }

    /// Change notification window (minutes). Clamps + persists + restarts clock.
    func setWindow(min: Double, max: Double) {
        var lo = min.rounded()
        var hi = max.rounded()
        lo = Swift.min(Swift.max(2, lo), 170)
        hi = Swift.min(Swift.max(lo + 1, hi), 180)
        minMinutes = lo
        maxMinutes = hi
        defaults.set(lo, forKey: minKey)
        defaults.set(hi, forKey: maxKey)
        scheduleNext(reason: "settings")
    }

    func randomInterval() -> TimeInterval {
        let lo = minMinutes * 60
        let hi = max(maxMinutes * 60, lo + 60)
        return Double.random(in: lo...hi)
    }

    /// Human summary, e.g. "10–30 min".
    var windowSummary: String {
        "\(Int(minMinutes))–\(Int(maxMinutes)) min"
    }

    func scheduleNext(reason: String) {
        timer?.invalidate()
        let now = Date()

        if pausedToday {
            nextCheck = nil
            return
        }

        if !isWorkTime(now) {
            // Jump to next work window
            if let next = nextWorkTime(after: now) {
                nextCheck = next
                let delay = next.timeIntervalSince(now)
                timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    self?.scheduleNext(reason: "window-open")
                }
            }
            return
        }

        let interval = randomInterval()
        var fire = now.addingTimeInterval(interval)
        // If fire lands outside window, clamp to next window instead
        if !isWorkTime(fire) {
            fire = nextWorkTime(after: now) ?? fire
        }
        nextCheck = fire
        let delay = max(1, fire.timeIntervalSince(now))
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.fire(trigger: "random")
        }
    }

    func fire(trigger: String = "manual") {
        onFire?(trigger)
        sendNotification()
        // Safety fallback: if user ignores the badge (never submits),
        // a fresh window still starts so prompts don't stall.
        // A submitted check-in calls recordCheckin() which restarts it.
        scheduleNext(reason: "fired")
    }

    /// Call on every submitted check-in: restart the 10-30 (or custom) window now.
    func recordCheckin() {
        scheduleNext(reason: "checkin")
    }

    func snooze(minutes: Double = 5) {
        timer?.invalidate()
        let fire = Date().addingTimeInterval(minutes * 60)
        nextCheck = fire
        timer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: false) { [weak self] _ in
            self?.fire(trigger: "snoozed")
        }
    }

    func pauseToday() {
        pausedToday = true
        timer?.invalidate()
        nextCheck = nil
    }

    func resume() {
        pausedToday = false
        scheduleNext(reason: "resume")
    }

    // MARK: - Work hours

    func isWorkTime(_ date: Date) -> Bool {
        let cal = Calendar.current
        let wd = cal.component(.weekday, from: date) // 1=Sun 7=Sat
        guard wd != 1 && wd != 7 else { return false }
        let hour = cal.component(.hour, from: date)
        return hour >= 9 && hour < 18
    }

    func nextWorkTime(after date: Date) -> Date? {
        var cal = Calendar.current
        cal.timeZone = .current
        var candidate = date
        // step forward: if before 9 today -> 9 today, else 9 next weekday
        for _ in 0..<10 {
            let startOfDay = cal.startOfDay(for: candidate)
            guard let nine = cal.date(byAdding: .hour, value: 9, to: startOfDay) else { return nil }
            let wd = cal.component(.weekday, from: startOfDay)
            let isWeekday = wd != 1 && wd != 7
            if isWeekday && candidate < nine {
                return nine
            }
            // move to next day midnight
            guard let nextDay = cal.date(byAdding: .day, value: 1, to: startOfDay) else { return nil }
            candidate = nextDay
        }
        return nil
    }

    // MARK: - Notifications

    private func requestNotificationAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, _ in
            self?.refreshNotificationStatus()
        }
        refreshNotificationStatus()
    }

    /// Re-checks system permission (user can flip it in Settings anytime).
    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let ok = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { self?.notificationsOK = ok }
        }
    }

    /// Native toast (top-right) + system sound. No focus steal, no popup.
    /// `.timeSensitive` lets it break through most Focus modes.
    /// The menu-bar icon badge (attention flag via onFire) is the backup cue.
    private func sendNotification() {
        let content = UNMutableNotificationContent()
        content.title = "WorkStats check-in"
        content.body = "Time for a quick check-in — click the 📊 icon in the menu bar."
        content.sound = .default
        if #available(macOS 12, *) {
            content.interruptionLevel = .timeSensitive
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // immediate
        ))
    }
}
