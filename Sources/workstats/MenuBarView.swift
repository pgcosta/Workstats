import SwiftUI
import AppKit
import ServiceManagement

struct MenuBarView: View {
    @ObservedObject var store: CheckinStore
    @ObservedObject var scheduler: Scheduler
    @Binding var lastTrigger: String
    @Binding var attention: Bool
    @Environment(\.openWindow) var openWindow
    /// Dismisses the dropdown popover itself (e.g. before showing Stats,
    /// so the popover doesn't cover the new window).
    @Environment(\.dismiss) var dismissPopover

    @State private var showForm = false
    @State private var revealNext = false
    @State private var showRhythm = false
    @State private var launchAtLogin = false
    @State private var loginError: String?
    @State private var todayEnergy = TodayEnergy()

    /// Matches persisted window to a preset, nil = custom (from older stepper UI).
    private var activePreset: (String, String, Double, Double)? {
        Scheduler.presets.first {
            Int(scheduler.minMinutes) == Int($0.2) && Int(scheduler.maxMinutes) == Int($0.3)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            TodayEnergyCard(energy: todayEnergy)

            if !scheduler.notificationsOK {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.slash.fill")
                            .foregroundStyle(.red)
                        Text("🔕 Notifications off — tap to enable")
                            .font(.callout.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .help("Without this you get badge-only nudges, no toast or sound")
            }

            if attention {
                HStack(spacing: 6) {
                    Image(systemName: "bell.badge.fill")
                        .foregroundStyle(.orange)
                    Text("Time for a check-in!")
                        .font(.callout.weight(.semibold))
                    Spacer()
                }
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

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
                    trigger: attention ? lastTrigger : "manual",
                    compact: true,
                    onSave: {
                        store.append($0)
                        scheduler.recordCheckin()
                        attention = false
                    },
                    onSnooze: {
                        scheduler.snooze()
                        attention = false
                    },
                    onCancel: {
                        attention = false
                        withAnimation { showForm = false }
                    }
                )
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()

            rhythmCard

            Divider()

            Group {
                rowButton("📈 Open Stats") {
                    openWindow(id: "stats")
                    dismissPopover()
                    NSApp.activate(ignoringOtherApps: true)
                }
                rowButton(scheduler.pausedToday ? "▶️ Resume" : "⏸️ Pause for today") {
                    scheduler.pausedToday ? scheduler.resume() : scheduler.pauseToday()
                }
                Toggle("🚀 Start at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                .help("Launch WorkStats automatically when you log in")
                if let err = loginError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                rowButton("📁 Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([CheckinStore.fileURL])
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            Divider()
            rowButton("❌ Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 324)
        .onAppear {
            refreshLoginStatus()
            scheduler.refreshNotificationStatus()
            refreshEnergy()
        }
        .onChange(of: store.todayCount) { _ in refreshEnergy() }
        .onChange(of: attention) { needs in
            if needs { withAnimation { showForm = true } }
        }
    }

    // MARK: - Full-row tappable menu buttons

    /// Plain buttons only hit-test their label by default, so clicks on the
    /// empty half of a row miss. Stretching the label + contentShape makes
    /// text, icon and whitespace all trigger the action.
    private func rowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
    }

    private func refreshEnergy() {
        todayEnergy = TodayEnergy.from(StatsEngine.load())
    }

    // MARK: - Launch at login (SMAppService, macOS 13+)

    private func refreshLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = on
            loginError = nil
        } catch {
            launchAtLogin = false
            loginError = "⚠️ System blocked it — do it manually: Settings → General → Login Items → + → WorkStats.app"
        }
    }

    // MARK: - Header: exact time hidden like a password field

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
            if scheduler.nextCheck != nil, !scheduler.pausedToday {
                HStack(spacing: 6) {
                    if revealNext, let next = scheduler.nextCheck {
                        Label("Next ~\(next, style: .time)", systemImage: "timer")
                        Spacer()
                        Button {
                            revealNext = false
                        } label: {
                            Image(systemName: "eye.slash")
                        }
                        .buttonStyle(.plain)
                        .help("Hide exact time")
                    } else {
                        Label("Next: ••:•• 🤫", systemImage: "timer")
                            .help("Hidden so you can't anticipate it")
                        Spacer()
                        Text(scheduler.windowSummary)
                            .foregroundStyle(.tertiary)
                        Button {
                            revealNext = true
                            autoHide()
                        } label: {
                            Image(systemName: "eye")
                        }
                        .buttonStyle(.plain)
                        .help("Reveal exact time (hides again in 15s)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if scheduler.pausedToday {
                Label("Paused today ⏸️", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Outside 9–18 weekdays 🌙", systemImage: "moon")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func autoHide() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            revealNext = false
        }
    }

    // MARK: - Prompt rhythm settings

    private var rhythmCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showRhythm.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("🔔 Prompt rhythm")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    if let p = activePreset {
                        Text("\(p.0) \(p.1) \(Int(p.2))–\(Int(p.3))m")
                    } else {
                        Text("✏️ Custom \(scheduler.windowSummary)")
                    }
                    Image(systemName: showRhythm ? "chevron.up" : "chevron.down")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showRhythm ? "Hide rhythm settings" : "Change prompt rhythm")

            if showRhythm {
                Text("After each check-in, the next surprise lands randomly in your window. Shorter = richer data, longer = fewer interruptions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(Scheduler.presets, id: \.1) { preset in
                        let active = Int(scheduler.minMinutes) == Int(preset.2) && Int(scheduler.maxMinutes) == Int(preset.3)
                        Button {
                            scheduler.setWindow(min: preset.2, max: preset.3)
                        } label: {
                            Text("\(preset.0) \(preset.1)\n\(Int(preset.2))–\(Int(preset.3))m")
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(active ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}
