# AGENTS.md — WorkStats contributor guide

Read this before changing code. Intended for AI coding agents (opencode etc.)
and humans. Stack: Swift 6, SwiftUI, no third-party deps, no Xcode needed.

## What the app is

Menu-bar-only macOS sampler for work sentiment. It pings the user at random
intervals on workdays, asks a 10-second check-in (working/leisure + three 1–5
sliders), appends to a CSV, and shows aggregate charts in a Stats window.

Core UX principles (do not regress):

- **Never intrusive.** No focus steal (`NSApp.activate` is banned on the
  prompt path), no auto-opening windows. Prompt = silent banner + Glass sound
  + `bell.badge.fill` menu icon + amber banner in the dropdown.
- **Surprise timing.** Exact next-fire time hidden behind 👁️ reveal (auto-hides
  in 15 s). Windows are random within the user's rhythm setting.
- **Lower-is-better exception.** Focus/accomplishment: 5 = green.
  Procrastination: 1 = green, 5 = red (`invertScale: true`, red tint).

## How it works (data flow)

1. `Scheduler` (StateObject in `WorkStatsApp`) owns a one-shot `Timer`.
   - App start → `scheduleNext("init")` → fires randomly in
     `[minMinutes, maxMinutes]` (defaults 10–30, persisted in UserDefaults
     keys `workstats.minMinutes` / `workstats.maxMinutes`).
   - Fire → `onFire?(trigger)` → `MenuBarBridge` sets `attention = true` +
     `lastTrigger`; `sendNotification()` posts a native toast with default
     sound (`.timeSensitive`) — never `NSApp.activate` (banned on prompt path).
     Then a safety fallback window is scheduled.
   - Submit (`recordCheckin()`) restarts the window from now. Snooze (5 min)
     short-circuits, then fires as `"snoozed"`. Skip just clears `attention`
     (fallback timer already pending).
   - Outside Mon–Fri 9:00–18:00 → timer jumps to next 9:00 weekday.
     `pausedToday` suppresses everything until resume.
2. `attention` (App-level `@State`) drives the `bell.badge.fill` icon and an
   amber "Time for a check-in!" banner in the dropdown; `.onChange` expands
   the inline form. Save/Snooze/Skip clear it.
3. `SurveyFormView` (in `SurveyView.swift`) builds a `Checkin`; callers append
   to `CheckinStore` (`~/Documents/workstats.csv`) and call
   `scheduler.recordCheckin()`. Manual entries use trigger `"manual"`.
4. `StatsView` re-parses the CSV via `StatsEngine.load()` on appear and on
   every `store.todayCount` change. All stats derive from working rows only;
   leisure rows count toward volume / working-%.

## Files

| File | Owns |
|---|---|
| `WorkStatsApp.swift` | `@main` App; `MenuBarExtra` + `stats` Window; `attention` flag; `MenuBarBridge` wiring |
| `MenuBarView.swift` | Dropdown: header (hidden next-time + 👁️), attention banner, inline form, rhythm presets, stats/CSV/quit actions, 🚀 login toggle |
| `SurveyView.swift` | `SurveyFormView` (sliders, badge colors, save flash); trigger labels |
| `Scheduler.swift` | Timer windows, work-hours gate, silent banner + sound, rhythm presets, login-independent |
| `Checkin.swift` | Model + `csvRow()`; CSV schema lives here |
| `CheckinStore.swift` | Append + `todayCount`; `static fileURL` |
| `StatsEngine.swift` | CSV parse, daily/hourly/weekday aggs, score, demo seeder |
| `StatsView.swift` | Charts + cards + day table; `StatsModel` |
| `Package.swift` | swift-tools 5.9, macOS 13+, executable `workstats` |
| `Info.plist` | `LSUIElement=true` (menu bar only), bundle id `com.workstats.app` |
| `build-app.sh` | `swift build -c release` → `WorkStats.app` bundle (+ `Assets/AppIcon.icns`, ad-hoc `codesign`, required for Notification Center identity) |
| `Assets/` | `MakeIcon.swift` (regenerates `AppIcon-master.png`; `iconutil` → `AppIcon.icns`); `Info.plist` points at it via `CFBundleIconFile` |

## CSV schema (do not break)

`timestamp,mode,focus_depth_1_5,procrastination_1_5,accomplished_1_5,trigger`
— ISO8601 UTC; mode `working|leisure`; sliders empty on leisure;
trigger `random|manual|snoozed|demo`. `StatsEngine.load()` must stay tolerant
(missing fractional seconds, short rows skipped).

Score (higher = better): `(focus + accomplishment + (6 − procrastination))/3`.

## Build / run / verify

```sh
swift build            # debug, needs only CLT Swift
./build-app.sh         # release → ./WorkStats.app
open WorkStats.app     # first launch: allow notifications
```

Always `swift build` after edits; also run `./build-app.sh` when the bundle
matters (Info.plist / packaging). Commit with conventional messages
(`feat:`, `fix:` …). Ignored: `.build/`, `WorkStats.app/`, `.DS_Store`.

## Experiment workflow (rollback-safe changes)

`main` is the stable line. Risky/exploratory work lives on branches:

```sh
git switch main && git pull        # start clean
git checkout -b exp/<name>         # experiment here
# …build, run, evaluate…
git add -A && git commit -m "exp: <what you tried>"
```

- Keep it: `git switch main && git merge exp/<name>`.
- Drop it: `git switch main && git branch -D exp/<name>` — main untouched.
- CSV data is never at risk (lives in `~/Documents`, outside git).

Past experiment: `exp/energy-orb` (plasma orb + streaks, see
`Gamification.swift`). Pattern for new dopamine/experiment ideas: new file +
small hooks in `MenuBarView`/`StatsView`, nothing in `Scheduler` unless the
prompt loop itself changes.

## Gotchas

- `openWindow` env works **only inside Views** — hence `MenuBarBridge`.
- Dropdown buttons must use the `rowButton()` helper (full-width label +
  `contentShape`) — plain buttons otherwise only hit-test their text.
- `MenuBarExtra` uses `.menuBarExtraStyle(.window)`; label closure swaps the
  icon based on `attention`.
- `onChange(of:)`: use the **single-param** form (deployment target is macOS 13).
- `NSBeep()` is unavailable in this SDK — use `NSSound.beep()` fallback.
- `SMAppService.mainApp` (🚀 toggle) throws on unsigned local builds; the UI
  already falls back to manual Login-Items instructions. Moving the app to
  `/Applications` helps registration succeed.
- `StatsEngine.seedDemoData` writes `trigger="demo"` rows — fine to keep, it
  powers the empty-state preview.
- Keep the prompt path free of `NSApp.activate(ignoringOtherApps:)` and
  `openWindow(id:"survey")` — the survey Window was removed on purpose.
