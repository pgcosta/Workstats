import SwiftUI
import AppKit
import ServiceManagement

struct MenuBarView: View {
    @ObservedObject var store: CheckinStore
    @ObservedObject var scheduler: Scheduler
    @ObservedObject var workdays: WorkdayStore
    @Binding var lastTrigger: String
    @Binding var attention: Bool
    @Environment(\.openWindow) var openWindow
    /// Dismisses the dropdown popover itself (e.g. before showing Stats,
    /// so the popover doesn't cover the new window).
    @Environment(\.dismiss) var dismissPopover

    @State private var showForm = false
    @State private var revealNext = false
    @State private var showRhythm = false
    @State private var showWorkdayEdit = false
    @State private var editStart = Date()
    @State private var editEnd = Date()
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

            TodayEnergyCard(energy: todayEnergy) {
                openWindow(id: "stats")
                dismissPopover()
                NSApp.activate(ignoringOtherApps: true)
            }

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

            // Hero action: the 10-second check-in is the whole point of the app.
            Button {
                withAnimation { showForm.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showForm ? "chevron.up" : "bolt.heart.fill")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(showForm ? "Hide check-in form"
                             : attention ? "🔔 Log your check-in!"
                             : "⚡️ Log how you're doing")
                            .font(.callout.weight(.bold))
                        if !showForm {
                            Text("10 seconds • working or leisure?")
                                .font(.caption2)
                                .opacity(0.9)
                        }
                    }
                    Spacer()
                    if attention {
                        Image(systemName: "bell.badge.fill")
                    }
                }
                .foregroundStyle(.white)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                LinearGradient(colors: [.blue, .purple],
                               startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 10)
            )

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
                        scheduler.skip()
                        withAnimation { showForm = false }
                    }
                )
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()

            workdayCard

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
        .onChange(of: todayEnergy.streak) { s in scheduler.celebrateStreakIfNew(s) }
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
                        Label(nextLabel(next), systemImage: "timer")
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
            } else if workdays.isOnBreakToday {
                Label("☕ On break — prompts paused", systemImage: "cup.and.saucer")
                    .font(.caption).foregroundStyle(.secondary)
            } else if workdays.isOpenToday {
                Label("🟢 On shift — prompts follow your day", systemImage: "clock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            } else if workdays.hasEndedToday {
                Label("Day wrapped up ✓", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if scheduler.manualOnly {
                Label("Manual mode — clock in to start prompts", systemImage: "clock")
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

    /// Date-aware reveal label: the old time-only label ("Next ~09:00") hid
    /// whether the fire is today or tomorrow, which made legit next-9:00
    /// scheduling look like a bug.
    private func nextLabel(_ date: Date) -> String {
        let t = DateFormatter()
        t.timeStyle = .short
        let time = t.string(from: date)
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today ~\(time)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow ~\(time)" }
        let d = DateFormatter()
        d.dateFormat = "EEE"
        return "\(d.string(from: date)) ~\(time)"
    }

    // MARK: - Workday clock-in/out (logon/logoff)

    /// Once-per-day clock-in. Deliberately NOT in the check-in form: start/end
    /// happen once, check-ins happen all day. One tap, editable after the fact
    /// (started at 9 but logging at 9:20). Times land in workstats_days.csv and
    /// power the early-bird stats; the prompt loop follows the shift.
    private var workdayCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("🕘 Workday")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(workdayStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let start = workdays.today?.start, let day = workdays.today {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        if let end = day.end {
                            Text("\(hm(start))–\(hm(end)) ✓")
                                .font(.callout.weight(.semibold))
                        } else if workdays.isOnBreakToday, let pause = day.breaks.last(where: { $0.resume == nil })?.pause {
                            Text("☕ On break since \(hm(pause))")
                                .font(.callout.weight(.semibold))
                        } else {
                            Text("Since \(hm(start)) 🟢")
                                .font(.callout.weight(.semibold))
                        }
                        Text(workdayReadout(day))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(showWorkdayEdit ? "Done" : "✏️") {
                        if !showWorkdayEdit { seedEdits() }
                        withAnimation { showWorkdayEdit.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Correct the logged time")
                }

                if showWorkdayEdit {
                    DatePicker("Start", selection: $editStart, displayedComponents: .hourAndMinute)
                        .font(.caption)
                        .onChange(of: editStart) { _ in
                            workdays.setStart(applyTime(editStart, to: Date()))
                        }
                    if workdays.today?.end != nil {
                        DatePicker("End", selection: $editEnd, displayedComponents: .hourAndMinute)
                            .font(.caption)
                            .onChange(of: editEnd) { _ in
                                workdays.setEnd(applyTime(editEnd, to: Date()))
                            }
                    }
                }

                if workdays.isOpenToday {
                    HStack(spacing: 8) {
                        if workdays.isOnBreakToday {
                            halfButton("▶ Back to work") { workdays.resumeToday() }
                        } else {
                            halfButton("⏸ Take a break") { workdays.pauseToday() }
                        }
                        halfButton("⏹ Clock out") { workdays.endDay() }
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.primary)
                } else {
                    HStack {
                        rowButton("↩ Reopen day") { workdays.reopenToday() }
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.primary)
                }
            } else {
                Button {
                    workdays.startDay()
                } label: {
                    HStack {
                        Text("▶ Start day")
                            .font(.callout.weight(.bold))
                        Spacer()
                        Text("clock in")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("One tap when work starts — prompts then follow your day, and Stats learns your early-bird pattern.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Manual prompts only", isOn: Binding(
                get: { scheduler.manualOnly },
                set: { scheduler.setManualOnly($0) }
            ))
            .font(.caption)
            .help(scheduler.manualOnly
                  ? "Prompts fire ONLY while clocked in — the 9–18 auto window is off"
                  : "Turn on to ignore 9–18: prompts start at clock-in, stop at clock-out")
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var workdayStatus: String {
        if workdays.isOnBreakToday { return "☕ on break" }
        if workdays.isOpenToday { return "🟢 on shift" }
        if workdays.hasEndedToday { return "done ✓" }
        return scheduler.manualOnly ? "waiting for clock-in" : "not started"
    }

    /// Half-width tappable button for the Break / Back / Clock-out row.
    private func halfButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(Rectangle())
        }
    }

    /// Net readout: active time minus breaks, e.g. "Active 5h12 • Breaks 0h45 (2)".
    private func workdayReadout(_ day: Workday) -> String {
        let a = workdays.activeSeconds(day)
        let b = workdays.breakSeconds(day)
        guard b >= 60 else { return "Active \(hmm(a)) • no breaks" }
        return "Active \(hmm(a)) • Breaks \(hmm(b)) (\(day.breaks.count))"
    }

    private func hmm(_ secs: Int) -> String {
        String(format: "%dh%02d", secs / 3600, (secs % 3600) / 60)
    }

    private func seedEdits() {
        if let s = workdays.today?.start { editStart = s }
        if let e = workdays.today?.end { editEnd = e }
    }

    private func hm(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: d)
    }

    /// Takes the wall-clock time from a DatePicker and pins it to today.
    private func applyTime(_ time: Date, to day: Date) -> Date {
        let cal = Calendar.current
        let t = cal.dateComponents([.hour, .minute], from: time)
        var d = cal.dateComponents([.year, .month, .day], from: day)
        d.hour = t.hour; d.minute = t.minute
        return cal.date(from: d) ?? time
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
