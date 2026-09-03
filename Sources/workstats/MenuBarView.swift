import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var store: CheckinStore
    @ObservedObject var scheduler: Scheduler
    @Binding var lastTrigger: String
    @Environment(\.openWindow) var openWindow

    @State private var showForm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            Button {
                withAnimation { showForm.toggle() }
            } label: {
                Label(showForm ? "Hide form" : "✏️ Check in now", systemImage: showForm ? "chevron.up" : "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(6)
            .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            if showForm {
                SurveyFormView(
                    trigger: "manual",
                    compact: true,
                    onSave: { store.append($0) },
                    onSnooze: { scheduler.snooze() },
                    onCancel: { withAnimation { showForm = false } }
                )
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()

            Group {
                Button("📈 Open Stats") {
                    openWindow(id: "stats")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button(scheduler.pausedToday ? "▶️ Resume" : "⏸️ Pause for today") {
                    scheduler.pausedToday ? scheduler.resume() : scheduler.pauseToday()
                }
                Button("📄 Open CSV") {
                    NSWorkspace.shared.open(CheckinStore.fileURL)
                }
                Button("📁 Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([CheckinStore.fileURL])
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            Divider()
            Button("❌ Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 324)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("📊 WorkStats")
                    .font(.headline)
                Spacer()
                Text("✅ \(store.todayCount)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.green.opacity(0.15), in: Capsule())
                    .help("check-ins today")
            }
            HStack(spacing: 4) {
                if let next = scheduler.nextCheck {
                    Label("Next: \(next, style: .time) ⏰", systemImage: "timer")
                } else if scheduler.pausedToday {
                    Label("Paused today ⏸️", systemImage: "pause.circle")
                } else {
                    Label("Outside 9–18 weekdays 🌙", systemImage: "moon")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
