import SwiftUI

// MARK: - Gamification experiment (branch exp/energy-orb)
//
// Idea: reward focused moments with visible energy. Today's working
// check-ins feed an "energy ball" (orb grows/brighter with positive focus)
// plus a 🔥 streak of consecutive focus>=4 check-ins. Positive-only:
// bad check-ins never shrink the orb below its floor, they just don't grow it.

/// Streak goal: consecutive focus>=4 check-ins. Hit it -> level-up toast.
let streakGoal = 3

/// Soft daily goal — feeds the progress ring, nothing else.
let dailyGoal = 8

struct TodayEnergy {
    var count = 0          // working check-ins today
    var lockedIn = 0       // …with focus >= 4
    var streak = 0         // trailing run of focus >= 4 (most recent first)
    var energy = 0.0       // 0...1 from today's composite score
    var avgFocus = 0.0
    var bestFocus: Checkin?

    var level: String {
        guard count > 0 else { return "💤 No fuel yet" }
        switch energy {
        case ..<0.2: return "🌱 Warming up"
        case ..<0.4: return "⚡️ Gathering steam"
        case ..<0.6: return "🔥 In flow"
        case ..<0.8: return "🌟 Radiant"
        default: return "🚀 Unstoppable"
        }
    }

    static func from(_ checkins: [Checkin]) -> TodayEnergy {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let rows = checkins
            .filter { $0.mode == .working && cal.isDate($0.timestamp, inSameDayAs: today) }
            .sorted { $0.timestamp < $1.timestamp }
        var e = TodayEnergy()
        e.count = rows.count
        guard !rows.isEmpty else { return e }
        let foci = rows.compactMap(\.focus)
        e.lockedIn = foci.filter { $0 >= 4 }.count
        e.avgFocus = foci.isEmpty ? 0 : Double(foci.reduce(0, +)) / Double(foci.count)
        e.bestFocus = rows.filter { ($0.focus ?? 0) >= 4 }.max { ($0.focus ?? 0) < ($1.focus ?? 0) }
        // Trailing streak: walk back from the latest check-in.
        var run = 0
        for r in rows.reversed() {
            guard (r.focus ?? 0) >= 4 else { break }
            run += 1
        }
        e.streak = run
        // Composite score 1...5 -> energy 0...1 (floor at 0.08 so orb never dies).
        let acc = rows.compactMap(\.accomplished)
        let pro = rows.compactMap(\.procrastination)
        let a = acc.isEmpty ? 3 : Double(acc.reduce(0, +)) / Double(acc.count)
        let p = pro.isEmpty ? 3 : Double(pro.reduce(0, +)) / Double(pro.count)
        let score = (e.avgFocus + a + (6 - p)) / 3
        e.energy = max(0.08, min(1, (score - 1) / 4))
        return e
    }
}

// MARK: - Plasma orb (Canvas, animated via TimelineView)

struct EnergyBall: View {
    var energy: Double // 0...1
    var size: CGFloat = 64

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            Canvas { ctx, sz in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                let R = min(sz.width, sz.height) / 2
                let pulse = 0.5 + 0.5 * sin(t * 2.2)
                // Outer glow (2 soft shells)
                for (frac, alpha) in [(1.0, 0.10 + 0.10 * energy), (0.72, 0.16 + 0.16 * energy)] {
                    let r = R * frac * (1 + 0.06 * pulse * energy)
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                        with: .color(glowColor.opacity(alpha))
                    )
                }
                // Core: bright center fading out
                let coreR = R * (0.34 + 0.30 * energy) * (1 + 0.05 * pulse)
                let core = Path(ellipseIn: CGRect(x: c.x - coreR, y: c.y - coreR, width: coreR * 2, height: coreR * 2))
                ctx.fill(core, with: .color(coreColor))
                ctx.fill(core, with: .color(.white.opacity(0.25 + 0.35 * energy)))
                // Orbiting sparks — more sparks when energy is high
                let sparks = 4 + Int(energy * 10)
                for i in 0..<sparks {
                    let fi = Double(i)
                    let speed = 0.9 + 0.4 * sin(fi * 1.7)
                    let ang = t * speed + fi * (2 * .pi / Double(max(sparks, 1)))
                    let orb = R * (0.62 + 0.22 * sin(t * 1.3 + fi * 2.1))
                    let p = CGPoint(x: c.x + orb * cos(ang), y: c.y + orb * sin(ang))
                    let sr = 1.5 + 2.5 * energy
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: p.x - sr, y: p.y - sr, width: sr * 2, height: sr * 2)),
                        with: .color(sparkColor.opacity(0.5 + 0.5 * energy))
                    )
                }
            }
        }
        .frame(width: size, height: size)
        .background(
            Circle()
                .fill(.quaternary.opacity(0.3))
                .frame(width: size, height: size)
        )
    }

    // Cold indigo -> warm gold as energy rises.
    private var glowColor: Color {
        Color(hue: 0.62 - 0.50 * energy, saturation: 0.75, brightness: 0.95)
    }
    private var coreColor: Color {
        Color(hue: 0.62 - 0.50 * energy, saturation: 0.85, brightness: 0.75)
    }
    private var sparkColor: Color {
        energy > 0.6 ? .yellow : .cyan
    }
}

// MARK: - Compact Today card (dropdown, orb opens Stats)

struct TodayEnergyCard: View {
    var energy: TodayEnergy
    var onOrbTap: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: onOrbTap) {
                    EnergyBall(energy: energy.energy, size: 56)
                }
                .buttonStyle(.plain)
                .help("Open stats")
                VStack(alignment: .leading, spacing: 4) {
                    Text(energy.level)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text("🧾 \(energy.count)/\(dailyGoal)")
                            .chip(.blue)
                        if energy.streak >= 2 {
                            Text("🔥 ×\(energy.streak)")
                                .chip(.orange)
                        } else if energy.lockedIn > 0 {
                            Text("⚡️ ×\(energy.lockedIn)")
                                .chip(.green)
                        }
                    }
                    .font(.caption.weight(.bold))
                }
                Spacer()
            }
            // Streak explainer + progress pips: the explicit goal.
            HStack(spacing: 6) {
                ForEach(0..<streakGoal, id: \.self) { i in
                    Circle()
                        .fill(i < min(energy.streak, streakGoal) ? Color.orange : Color.secondary.opacity(0.25))
                        .frame(width: 10, height: 10)
                }
                Text(streakText)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var streakText: String {
        if energy.streak >= streakGoal {
            return "Streak goal smashed 🎉 — keep riding it"
        }
        return "Log focus 4–5, \(streakGoal)× in a row → 🔥 (\(min(energy.streak, streakGoal))/\(streakGoal))"
    }
}

private extension View {
    /// Solid high-contrast chip — readable on any translucent background.
    func chip(_ color: Color) -> some View {
        self.padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
            .foregroundStyle(.white)
    }
}

// MARK: - Stats "Today" section (positives only)

struct TodaySpotlight: View {
    var energy: TodayEnergy

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("☀️ Today — keep the streak alive")
                .font(.headline)
            HStack(spacing: 20) {
                EnergyBall(energy: energy.energy, size: 120)
                VStack(alignment: .leading, spacing: 6) {
                    Text(energy.level)
                        .font(.title3.bold())
                    if energy.count == 0 {
                        Text("Log your first check-in and watch this ignite.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        winRow(emoji: "🎯", text: String(format: "Avg focus %.1f", energy.avgFocus))
                        if energy.lockedIn > 0 {
                            winRow(emoji: "⚡️", text: "\(energy.lockedIn) locked-in moment\(energy.lockedIn == 1 ? "" : "s") (focus 4–5)")
                        }
                        if energy.streak >= streakGoal {
                            winRow(emoji: "🎉", text: "STREAK GOAL ×\(streakGoal) smashed — Unstoppable mode")
                        } else if energy.streak >= 2 {
                            winRow(emoji: "🔥", text: "\(energy.streak)-in-a-row — \(streakGoal - energy.streak) more to goal ×\(streakGoal)")
                        }
                        if let best = energy.bestFocus {
                            winRow(emoji: "🏆", text: "Peak at \(Self.time(best.timestamp)) — focus \(best.focus ?? 0)/5")
                        }
                        winRow(emoji: "🧾", text: "\(energy.count)/\(dailyGoal) check-ins toward today's rhythm")
                    }
                }
            }
            ProgressView(value: min(Double(energy.count) / Double(dailyGoal), 1))
                .tint(.green)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
    }

    private func winRow(emoji: String, text: String) -> some View {
        Text("\(emoji) \(text)")
            .font(.callout)
    }

    private static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: d)
    }
}
