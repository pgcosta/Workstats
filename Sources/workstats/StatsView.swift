import SwiftUI
import Charts
import AppKit

enum StatsRange: Int, CaseIterable, Identifiable {
    case week = 7, month = 30, quarter = 90, all = 0
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .week: return "7d"
        case .month: return "30d"
        case .quarter: return "90d"
        case .all: return "All"
        }
    }
}

final class StatsModel: ObservableObject {
    @Published var checkins: [Checkin] = []
    @Published var range: StatsRange = .month

    var filtered: [Checkin] {
        guard range != .all else { return checkins }
        let cutoff = Calendar.current.date(byAdding: .day, value: -range.rawValue, to: Date()) ?? Date()
        return checkins.filter { $0.timestamp >= cutoff }
    }
    var days: [StatsEngine.DayStat] { StatsEngine.daily(filtered) }
    var points: [StatsEngine.MetricPoint] { StatsEngine.metricPoints(days) }
    var hours: [StatsEngine.HourStat] { StatsEngine.hourlyFocus(filtered) }
    var weekdays: [StatsEngine.WeekdayStat] { StatsEngine.weekdayFocus(filtered) }
    var summary: StatsEngine.Summary { StatsEngine.summary(checkins: filtered, days: days, hours: hours, weekdays: weekdays) }

    func reload() { checkins = StatsEngine.load() }
}

struct StatsView: View {
    @StateObject private var vm = StatsModel()
    @ObservedObject var store: CheckinStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if vm.checkins.isEmpty {
                    emptyState
                } else {
                    TodaySpotlight(energy: TodayEnergy.from(vm.checkins))
                    summaryCards
                    dailyCard
                    trendCard
                    HStack(alignment: .top, spacing: 16) {
                        hourCard
                        weekdayCard
                    }
                    dayTable
                }
                footer
            }
            .padding(24)
        }
        .frame(minWidth: 860, minHeight: 620)
        .onAppear { vm.reload() }
        .onReceive(store.$todayCount) { _ in vm.reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("📈 WorkStats insights")
                    .font(.title2.bold())
                Text("Daily averages • best/worst days • focus hours")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $vm.range) {
                ForEach(StatsRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            Button("↻ Refresh") { vm.reload() }
            Button("📄 CSV") { NSWorkspace.shared.open(CheckinStore.fileURL) }
        }
    }

    // MARK: - Summary

    private var summaryCards: some View {
        let s = vm.summary
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            StatCard(emoji: "🧾", title: "Check-ins", value: "\(s.total)", sub: String(format: "%.0f%% working", s.workingPct), color: .blue)
            StatCard(emoji: "🎯", title: "Avg focus", value: fmt(s.avgFocus), sub: "1–5 scale", color: .purple)
            StatCard(emoji: "🌀", title: "Avg procrast.", value: fmt(s.avgProcrast), sub: "lower = better", color: .orange)
            StatCard(emoji: "🏆", title: "Avg accompl.", value: fmt(s.avgAccomp), sub: "feeling of accomplishment", color: .green)
            StatCard(emoji: "🌟", title: "Best day", value: s.bestDay?.label ?? "—", sub: s.bestDay?.score.map { String(format: "score %.1f", $0) } ?? "", color: .green)
            StatCard(emoji: "🐌", title: "Toughest day", value: s.worstDay?.label ?? "—", sub: s.worstDay?.score.map { String(format: "score %.1f", $0) } ?? "", color: .red)
            StatCard(emoji: "⏰", title: "Peak focus hour", value: s.bestHour.map { "\($0.hour)h" } ?? "—", sub: s.bestHour.map { String(format: "%.1f avg • %d logs", $0.focus, $0.count) } ?? "", color: .mint)
            StatCard(emoji: "📅", title: "Best weekday", value: s.bestWeekday?.name ?? "—", sub: s.bestWeekday.map { String(format: "%.1f avg focus", $0.focus) } ?? "", color: .indigo)
        }
    }

    // MARK: - Charts

    private var dailyCard: some View {
        chartCard(title: "📊 Daily averages — 3 bars per day", sub: "Mean of working check-ins that day") {
            if vm.points.isEmpty {
                Text("No working data in range").foregroundStyle(.secondary)
            } else {
                Chart(vm.points) {
                    BarMark(
                        x: .value("Day", $0.dayLabel),
                        y: .value("Avg", $0.value),
                        width: .fixed(10)
                    )
                    .position(by: .value("Metric", $0.metric))
                    .foregroundStyle(by: .value("Metric", $0.metric))
                }
                .chartForegroundStyleScale([
                    "🎯 Focus": Color.purple,
                    "🌀 Procrast.": Color.orange,
                    "🏆 Accompl.": Color.green
                ])
                .chartYScale(domain: 0...5.5)
                .chartYAxis { AxisMarks(values: [0, 1, 2, 3, 4, 5]) }
                .frame(height: 240)
            }
        }
    }

    private var trendCard: some View {
        chartCard(title: "🌊 Overall score trend", sub: "Score = (focus + accomplishment + (6 − procrastination)) / 3") {
            let scored = vm.days.filter { $0.score != nil }
            if scored.isEmpty {
                Text("Not enough data yet").foregroundStyle(.secondary)
            } else {
                Chart(scored) {
                    LineMark(x: .value("Day", $0.label), y: .value("Score", $0.score ?? 0))
                        .foregroundStyle(.blue)
                        .interpolationMethod(.catmullRom)
                    PointMark(x: .value("Day", $0.label), y: .value("Score", $0.score ?? 0))
                        .foregroundStyle(.blue)
                    RuleMark(y: .value("Avg", vm.summary.avgScore))
                        .lineStyle(StrokeStyle(dash: [5, 4]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .trailing) {
                            Text(String(format: "avg %.1f", vm.summary.avgScore))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                }
                .chartYScale(domain: 0...5.5)
                .frame(height: 180)
            }
        }
    }

    private var hourCard: some View {
        chartCard(title: "⏰ Focus by hour", sub: "When do you focus best?") {
            if vm.hours.isEmpty {
                Text("No data").foregroundStyle(.secondary)
            } else {
                let best = vm.summary.bestHour?.hour
                Chart(vm.hours) { h in
                    BarMark(x: .value("Hour", h.label), y: .value("Focus", h.focus))
                        .foregroundStyle(h.hour == best ? Color.mint : Color.blue.opacity(0.6))
                        .annotation(position: .top) {
                            Text(String(format: "%.1f", h.focus)).font(.caption2)
                        }
                }
                .chartYScale(domain: 0...5.5)
                .frame(height: 200)
            }
        }
    }

    private var weekdayCard: some View {
        chartCard(title: "📅 Focus by weekday", sub: "Best vs worst days of week") {
            if vm.weekdays.isEmpty {
                Text("No data").foregroundStyle(.secondary)
            } else {
                Chart(vm.weekdays) { w in
                    BarMark(x: .value("Day", w.name), y: .value("Focus", w.focus))
                        .foregroundStyle(Color.indigo.opacity(0.75))
                        .annotation(position: .top) {
                            Text(String(format: "%.1f", w.focus)).font(.caption2)
                        }
                }
                .chartYScale(domain: 0...5.5)
                .frame(height: 200)
            }
        }
    }

    private var dayTable: some View {
        chartCard(title: "🗓️ Day-by-day", sub: "Sorted oldest → newest") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Day").bold(); Text("Logs").bold()
                    Text("🎯").bold(); Text("🌀").bold(); Text("🏆").bold(); Text("Score").bold()
                }
                .font(.caption).foregroundStyle(.secondary)
                Divider()
                ForEach(vm.days) { d in
                    GridRow {
                        Text(d.label)
                        Text("\(d.count)")
                        Text(d.focus.map { String(format: "%.1f", $0) } ?? "—")
                        Text(d.procrast.map { String(format: "%.1f", $0) } ?? "—")
                        Text(d.accomp.map { String(format: "%.1f", $0) } ?? "—")
                        Text(d.score.map { String(format: "%.1f", $0) } ?? "—")
                            .bold()
                            .foregroundStyle(scoreColor(d.score))
                    }
                    .font(.callout).monospacedDigit()
                }
            }
        }
    }

    // MARK: - Empty / footer

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("🌱 No data yet")
                .font(.title3.bold())
            Text("Log a few check-ins and graphs appear here.\nWant a preview? Seed 2 weeks of demo data.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("✨ Seed demo data") {
                StatsEngine.seedDemoData(store: store)
                vm.reload()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    private var footer: some View {
        HStack {
            Text("Score rewards focus + accomplishment, penalizes procrastination.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("✨ Add demo data") {
                StatsEngine.seedDemoData(store: store)
                vm.reload()
            }
            .font(.caption)
        }
    }

    // MARK: - Helpers

    private func chartCard<Content: View>(title: String, sub: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(sub).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
    }

    private func fmt(_ v: Double) -> String { v == 0 ? "—" : String(format: "%.1f", v) }

    private func scoreColor(_ s: Double?) -> Color {
        guard let s else { return .secondary }
        if s >= 4 { return .green }
        if s >= 3 { return .mint }
        if s >= 2.5 { return .orange }
        return .red
    }
}

struct StatCard: View {
    var emoji: String
    var title: String
    var value: String
    var sub: String
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(emoji) \(title)")
                .font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}
