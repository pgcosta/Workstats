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
    /// Shift state, synced from WorkdayStore by MenuBarBridge (Scheduler
    /// doesn't own the store to keep the prompt loop dependency-free).
    /// While a shift is open prompts fire even outside 9-18; after clock-out
    /// the day is done. Stale flags (synced yesterday) are ignored via shiftDay.
    @Published var shiftOpen = false
    @Published var shiftEndedToday = false
    @Published var shiftDay: Date?
    /// Mid-shift break (bathroom, lunch…). Prompts pause until back.
    @Published var onBreak = false
    /// When on, prompts fire ONLY while clocked in — the 9-18 auto window is
    /// off. Default off (no behavior change until the user opts in).
    @Published var manualOnly = false

    private var timer: Timer?
    private var reminderTimer: Timer?
    /// Set on fire, cleared on submit/snooze/skip. Drives the 60 s re-nudge:
    /// if user missed the toast (no visual cue seen), a second sound +
    /// banner lands while the check-in is still pending.
    private var pendingSince: Date?
    private let defaults = UserDefaults.standard
    private let minKey = "workstats.minMinutes"
    private let maxKey = "workstats.maxMinutes"
    private let manualKey = "workstats.manualOnly"

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
        self.manualOnly = defaults.bool(forKey: manualKey)
        requestNotificationAuth()
        scheduleNext(reason: "init")
    }

    /// Toggle manual-only prompts (only while clocked in). Persists + restarts clock.
    func setManualOnly(_ on: Bool) {
        manualOnly = on
        defaults.set(on, forKey: manualKey)
        scheduleNext(reason: "settings")
    }

    /// Called by MenuBarBridge whenever WorkdayStore changes.
    func syncShift(open: Bool, endedToday: Bool, onBreak: Bool, day: Date?) {
        shiftOpen = open
        shiftEndedToday = endedToday
        self.onBreak = onBreak
        shiftDay = day
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

    /// Shift flags synced from yesterday are dead — a new day starts clean
    /// (legacy 9-18 or idle manual-only until next clock-in).
    private func dropStaleShiftFlags(now: Date = Date()) {
        if let d = shiftDay, !Calendar.current.isDate(d, inSameDayAs: now) {
            shiftOpen = false
            shiftEndedToday = false
            onBreak = false
            shiftDay = nil
        }
    }

    func scheduleNext(reason: String) {
        timer?.invalidate()
        let now = Date()
        dropStaleShiftFlags(now: now)

        if pausedToday {
            nextCheck = nil
            return
        }

        // Mid-shift break: silent until back (resume re-arms via syncShift).
        if onBreak {
            nextCheck = nil
            return
        }

        // Clocked out: day is done. Manual-only idles until next clock-in,
        // legacy parks until tomorrow 9:00.
        if shiftEndedToday {
            if manualOnly {
                nextCheck = nil
                return
            }
            if let next = nextWorkTime(after: now) {
                nextCheck = next
                let delay = next.timeIntervalSince(now)
                timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    self?.scheduleNext(reason: "window-open")
                }
            } else {
                nextCheck = nil
            }
            return
        }

        // Manual-only: silence until clock-in.
        if manualOnly && !shiftOpen {
            nextCheck = nil
            return
        }

        if !isWorkTime(now) && !shiftOpen {
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
        // If fire lands outside window, clamp to next window instead.
        // An open shift stretches the window: no clamping while clocked in.
        if !isWorkTime(fire) && !shiftOpen {
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
        pendingSince = Date()
        scheduleReminder()
        sendNotification()
        // Safety fallback: if user ignores the badge (never submits),
        // a fresh window still starts so prompts don't stall.
        // A submitted check-in calls recordCheckin() which restarts it.
        scheduleNext(reason: "fired")
    }

    /// Call on every submitted check-in: restart the 10-30 (or custom) window now.
    func recordCheckin() {
        clearPending()
        scheduleNext(reason: "checkin")
    }

    /// Skip = "not now": same fresh window as a submit, restarted at skip time.
    /// (Previously Skip kept the stale fallback computed at fire time, which
    /// is why the revealed time could surprise — e.g. tomorrow 09:00.)
    func skip() {
        clearPending()
        scheduleNext(reason: "skipped")
    }

    func snooze(minutes: Double = 5) {
        clearPending()
        timer?.invalidate()
        let fire = Date().addingTimeInterval(minutes * 60)
        nextCheck = fire
        timer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: false) { [weak self] _ in
            self?.fire(trigger: "snoozed")
        }
    }

    func pauseToday() {
        clearPending()
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

    /// Level-up moment: once per day, a streak hitting the goal fires a
    /// celebratory toast + sound. Called from the streak watcher.
    func celebrateStreakIfNew(_ streak: Int) {
        guard streak >= streakGoal else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let key = "workstats.celebratedStreak.\(f.string(from: Date()))"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        let content = UNMutableNotificationContent()
        content.title = "🔥 Focus streak ×\(streak)!"
        content.body = "Three locked-in check-ins in a row. Ride the wave 🌊"
        content.sound = .default
        if #available(macOS 12, *) {
            content.interruptionLevel = .timeSensitive
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }

    /// Native toast (top-right) + system sound. No focus steal, no popup.
    /// `.timeSensitive` lets it break through most Focus modes.
    /// The menu-bar icon badge (attention flag via onFire) is the backup cue.
    private func sendNotification() {
        playPing()
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

    /// Second nudge 60 s after fire, only while check-in still pending.
    /// Covers missed-toast case: user busy, no visual cue seen.
    private func scheduleReminder() {
        reminderTimer?.invalidate()
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            guard let self, self.pendingSince != nil else { return }
            self.sendReminder()
        }
    }

    private func clearPending() {
        pendingSince = nil
        reminderTimer?.invalidate()
        reminderTimer = nil
    }

    private func sendReminder() {
        playPing()
        let content = UNMutableNotificationContent()
        content.title = "WorkStats check-in — still waiting"
        content.body = "Quick check-in still pending — click the 📊 icon (orange dot) in the menu bar."
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

    /// Local Glass ping alongside the toast sound — audible even if the
    /// banner auto-dismisses or Notification Center groups it away.
    private func playPing() {
        if let s = NSSound(named: "Glass") {
            s.play()
        } else {
            NSSound.beep()
        }
    }
}
