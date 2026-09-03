import SwiftUI
import AppKit

@main
struct WorkStatsApp: App {
    @StateObject private var store = CheckinStore()
    @StateObject private var scheduler = Scheduler()
    @State private var lastTrigger = "random"
    /// Soft-alert flag: bell badge on the menu icon until the user checks in.
    @State private var attention = false

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

        Window("Stats", id: "stats") {
            StatsView(store: store)
        }
        .defaultPosition(.center)
    }
}

/// Wires scheduler fires to the soft-alert flag. No popups, no focus steal:
/// the user notices the 🔔 badge + sound and checks in via the dropdown.
struct MenuBarBridge: View {
    @ObservedObject var store: CheckinStore
    @ObservedObject var scheduler: Scheduler
    @Binding var lastTrigger: String
    @Binding var attention: Bool

    var body: some View {
        MenuBarView(store: store, scheduler: scheduler, lastTrigger: $lastTrigger, attention: $attention)
            .onAppear {
                scheduler.onFire = { trigger in
                    lastTrigger = trigger
                    attention = true
                }
            }
    }
}
