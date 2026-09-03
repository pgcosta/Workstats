import Foundation
import AppKit
import UserNotifications
import Combine

/// Fires random prompts every 20-40 min, Mon-Fri 9:00-18:00.
/// Outside window: schedules next check at next 9:00 weekday.
final class Scheduler: ObservableObject {
    @Published var nextCheck: Date?
    @Published var pausedToday = false

    private var timer: Timer?
    private let minInterval: TimeInterval = 20 * 60
    private let maxInterval: TimeInterval = 40 * 60

    var onFire: ((String) -> Void)?

    init() {
        requestNotificationAuth()
        scheduleNext(reason: "init")
    }

    func randomInterval() -> TimeInterval {
        Double.random(in: minInterval...maxInterval)
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

        let interval = reason == "init" ? randomInterval() : randomInterval()
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
        // Chain next random slot
        scheduleNext(reason: "fired")
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendNotification() {
        let content = UNMutableNotificationContent()
        content.title = "WorkStats check-in"
        content.body = "Working or leisure? Tap to log focus."
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // immediate
        )
        UNUserNotificationCenter.current().add(req)
        // Bring survey window forward
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
