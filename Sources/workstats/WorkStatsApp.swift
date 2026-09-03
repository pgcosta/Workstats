import SwiftUI
import AppKit

@main
struct WorkStatsApp: App {
    @StateObject private var store = CheckinStore()
    @StateObject private var scheduler = Scheduler()
    @State private var lastTrigger = "random"

    var body: some Scene {
        MenuBarExtra("WorkStats", systemImage: "chart.bar") {
            MenuBarBridge(
                store: store,
                scheduler: scheduler,
                lastTrigger: $lastTrigger
            )
        }
        .menuBarExtraStyle(.window)

        Window("Check-in", id: "survey") {
            SurveyView(
                trigger: lastTrigger,
                onSave: { store.append($0) },
                onSnooze: { scheduler.snooze() }
            )
            .onDisappear { store.refreshTodayCount() }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Stats", id: "stats") {
            StatsView(store: store)
        }
        .defaultPosition(.center)
    }
}

/// Captures openWindow env (only valid inside a View) and wires scheduler.
/// Manual check-ins stay inline in dropdown; random/snoozed open popup Window.
struct MenuBarBridge: View {
    @ObservedObject var store: CheckinStore
    @ObservedObject var scheduler: Scheduler
    @Binding var lastTrigger: String
    @Environment(\.openWindow) var openWindow

    var body: some View {
        MenuBarView(store: store, scheduler: scheduler, lastTrigger: $lastTrigger)
            .onAppear {
                scheduler.onFire = { trigger in
                    lastTrigger = trigger
                    openWindow(id: "survey")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}
