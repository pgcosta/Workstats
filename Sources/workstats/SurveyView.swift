import SwiftUI

/// Check-in form, embedded in the menu-bar dropdown.
/// Direction of "good": focus/accomplishment are higher-is-better, but
/// procrastination is lower-is-better, so its badge scale is inverted
/// (1 = green, 5 = red) and its slider tint is red.
struct SurveyFormView: View {
    var trigger: String = "random"
    var compact: Bool = false
    var onSave: (Checkin) -> Void
    var onSnooze: () -> Void
    var onCancel: (() -> Void)? = nil

    @State private var mode: ActivityMode = .working
    @State private var focus: Double = 3
    @State private var procrastination: Double = 3
    @State private var accomplished: Double = 3
    @State private var savedFlash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Picker("Right now:", selection: $mode) {
                Text("💼 Working").tag(ActivityMode.working)
                Text("☕ Leisure").tag(ActivityMode.leisure)
            }
            .pickerStyle(.segmented)

            if mode == .working {
                sliderRow(
                    emoji: "🎯", title: "Focus depth",
                    value: $focus, tint: .purple,
                    hints: ["scattered", "deep"]
                )
                sliderRow(
                    emoji: "🌀", title: "Procrastination",
                    value: $procrastination, tint: .red,
                    hints: ["none 😌", "heavy 😬"],
                    invertScale: true
                )
                sliderRow(
                    emoji: "🏆", title: "Feeling of accomplishment",
                    value: $accomplished, tint: .green,
                    hints: ["stuck", "flying"]
                )
            } else {
                Label("Enjoy your break 🌿 — just hit Save.", systemImage: "cup.and.saucer")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("😴 5m") {
                    onSnooze()
                    onCancel?()
                }
                .help("Snooze 5 minutes")
                Spacer()
                if onCancel != nil {
                    Button("Skip") { onCancel?() }
                        .keyboardShortcut(.cancelAction)
                }
                Button(savedFlash ? "✅ Saved!" : "💾 Save") {
                    let c = Checkin(
                        timestamp: Date(),
                        mode: mode,
                        focus: mode == .working ? Int(focus) : nil,
                        procrastination: mode == .working ? Int(procrastination) : nil,
                        accomplished: mode == .working ? Int(accomplished) : nil,
                        trigger: trigger
                    )
                    onSave(c)
                    savedFlash = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        savedFlash = false
                        onCancel?()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
        }
        .padding(compact ? 12 : 20)
        .frame(width: compact ? 300 : 340)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("⚡️ Quick check-in")
                .font(.headline)
            Text(triggerLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var triggerLabel: String {
        switch trigger {
        case "manual": return "✋ Manual entry"
        case "snoozed": return "😴 Snoozed follow-up"
        default: return "🎲 Random sample • \(trigger)"
        }
    }

    private func sliderRow(emoji: String, title: String, value: Binding<Double>, tint: Color, hints: [String], invertScale: Bool = false) -> some View {
        let v = Int(value.wrappedValue)
        let color = ratingColor(v, inverted: invertScale)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(emoji) \(title)")
                Spacer()
                Text("\(v) / 5")
                    .monospacedDigit()
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.15), in: Capsule())
                    .foregroundStyle(color)
            }
            .font(.callout)
            Slider(value: value, in: 1...5, step: 1)
                .tint(tint)
            HStack {
                Text(hints[0]).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(hints[1]).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Standard 1=red … 5=green; inverted for lower-is-better metrics.
    private func ratingColor(_ v: Int, inverted: Bool = false) -> Color {
        let scale: [Color] = [.red, .orange, .yellow, .mint, .green]
        let idx = min(max(v - 1, 0), 4)
        return inverted ? scale[4 - idx] : scale[idx]
    }
}

/// Standalone panel for the user-initiated "Check in" window
/// (opened by tapping the notification toast — never auto-opened).
struct CheckinPanel: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var store: CheckinStore
    @ObservedObject var scheduler: Scheduler
    @Binding var lastTrigger: String
    @Binding var attention: Bool

    var body: some View {
        SurveyFormView(
            trigger: lastTrigger,
            onSave: {
                store.append($0)
                scheduler.recordCheckin()
                attention = false
                dismiss()
            },
            onSnooze: {
                scheduler.snooze()
                attention = false
                dismiss()
            },
            onCancel: {
                attention = false
                dismiss()
            }
        )
        .onDisappear { store.refreshTodayCount() }
    }
}
