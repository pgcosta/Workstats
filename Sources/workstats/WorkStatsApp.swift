import SwiftUI
import AppKit
import UserNotifications

/// Routes notification taps: the system opens the app, we open the CHECK-IN
/// window (never Stats — that was the bug). Set as UNUserNotificationCenter
/// delegate at launch; Views can't do this, so it posts via NotificationCenter
/// and MenuBarBridge (which owns the openWindow env) performs the open.
final class CheckinTapRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CheckinTapRouter()
    static let openCheckin = Notification.Name("workstats.openCheckin")

    // Show the toast even when the app is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // User tapped the toast -> ask bridge to open the check-in window.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        NotificationCenter.default.post(name: Self.openCheckin, object: nil)
    }
}

@main
struct WorkStatsApp: App {
    @StateObject private var store = CheckinStore()
    @StateObject private var scheduler = Scheduler()
    @State private var lastTrigger = "random"
    /// Soft-alert flag: bell badge on the menu icon until the user checks in.
    @State private var attention = false

    init() {
        UNUserNotificationCenter.current().delegate = CheckinTapRouter.shared
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarBridge(
                store: store,
                scheduler: scheduler,
                lastTrigger: $lastTrigger,
                attention: $attention
            )
        } label: {
            Label("WorkStats", systemImage: attention ? "bell.badge.fill" : "chart.bar")
        }
        .menuBarExtraStyle(.window)

        // User-initiated only (notification tap). Never auto-opened on fire.
        Window("Check in", id: "checkin") {
            CheckinPanel(
                store: store,
                scheduler: scheduler,
                lastTrigger: $lastTrigger,
                attention: $attention
            )
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Stats", id: "stats") {
            StatsView(store: store)
        }
        .defaultPosition(.center)
    }
}

/// Wires scheduler fires to the soft-alert flag. No popups, no focus steal:
/// the user notices the 🔔 badge + sound and checks in via the dropdown
/// (or taps the toast, which opens the check-in window via router above).
struct MenuBarBridge: View {
    @ObservedObject var store: CheckinStore
    @ObservedObject var scheduler: Scheduler
    @Binding var lastTrigger: String
    @Binding var attention: Bool
    @Environment(\.openWindow) var openWindow

    var body: some View {
        MenuBarView(store: store, scheduler: scheduler, lastTrigger: $lastTrigger, attention: $attention)
            .onAppear {
                scheduler.onFire = { trigger in
                    lastTrigger = trigger
                    attention = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: CheckinTapRouter.openCheckin)) { _ in
                openWindow(id: "checkin")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}
