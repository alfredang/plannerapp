# Planner for Mac (PlannerAppMac target)

Desktop edition of Tertiary Planner, shipped as a Developer ID–signed, notarized DMG (not on
the Mac App Store). Same data as the iPhone app via SwiftData + CloudKit. The iPhone app's
notes are in `../PlannerApp/CLAUDE.md`.

## Project layout and code sharing

- XcodeGen: `project.yml` is the source of truth; `PlannerApp.xcodeproj/` is generated and
  gitignored. Run `xcodegen generate` after adding/removing files or changing settings.
- The Mac target compiles `PlannerAppMac/` **plus** all of `PlannerApp/Models`,
  `PlannerApp/Services`, `PlannerApp/Theme`, `PlannerApp/Assets.xcassets`, and eight
  hand-listed iOS views (`ItemRow`, `FollowUpActionsView`, `AddItemView`, `ListsManagerView`,
  `ArchiveView`, `FeedbackView`, `AboutView`, `RemindersSettingsView`).
  - Any new file in those shared folders must build on macOS too (guard with `#if os(iOS)`).
  - Sharing another iOS view means adding it to the `PlannerAppMac` sources in `project.yml`.
- `PRODUCT_NAME: Planner` → the app is `Planner.app`, binary `Contents/MacOS/Planner`.
- Bundle id `com.tertiaryinfotech.plannerapp` (same as iOS), team `GU9WTSTX9M`, macOS 14+.
- Mac overrides `CURRENT_PROJECT_VERSION` (currently "36") separately from the iOS base value;
  `MARKETING_VERSION` is shared.
- SwiftTerm is pinned `exactVersion: 1.11.2` — 1.12+ needs the Xcode Metal toolchain. Don't bump.

## Architecture

- `App/PlannerMacApp.swift` — `@main`; schema `[PlannerItem, PlannerList, AgentReport,
  ReportReply]`, `cloudKitDatabase: .automatic`, local/in-memory fallback. Starts
  `UpdatesSync` + `AppointmentAgent`; app delegate applies appearance and calls
  `HermesBridge.prepareWorkspace()`. Closing the window does not quit.
- `Views/MacRootView.swift` — `NavigationSplitView`; `SidebarItem` enum (To-Do, Pinned, Today,
  Upcoming, Appointments, Calendar, Schedule (`jobs`), Updates, Archive, Settings, Feedback,
  About) + user lists (`ListHierarchy`) + Digital Workforce staff.
- Panes: `MacPlannerPane` (items + capture bar), `MacCalendarPane`, `MacUpdatesPane`,
  `MacSchedulePane` (workforce LaunchAgents `com.alfred.workforce.*`, Hermes/OpenClaw cron),
  `MacDashboardPane` (Sidebar ▸ Dashboard: Hermes web UI on http://127.0.0.1:9119, started
  on demand and kept up by `~/DigitalWorkforce/bin/hermes-watchdog.py`; or the OpenClaw
  Control UI via `~/.openclaw/bin/openclaw dashboard --json`),
  `MacSettingsPane` (Settings scene, ⌘,), `MacAgentProfileView`/`MacAgentChatView`/
  `DigitalWorkforceArtifactView`.
- `Views/MacTerminalPanel.swift` — right-hand agent panel (⌥⌘T, `hermesPanelVisible`):
  SwiftTerm tabs for `TerminalAgent` = claude / codex / hermes / openclaw (front tab in
  `terminalAgent` AppStorage), all started at launch by `AgentPanelTabs.shared.startAll()`.
  `MacBrowserPanel.swift` is the panel's Browser tab (reports in `<workspace>/reports/`).
- `Services/HermesBridge.swift` — agent ⇄ SwiftData bridge in the workspace
  `~/Library/Application Support/Planner/Hermes/`: `planner-state.json` snapshot (rewritten
  on every data change), `AGENTS.md` (+ `CLAUDE.md` = `@AGENTS.md`), `planner-log.txt`,
  `memory/`, and the Hermes skill `~/.hermes/skills/productivity/planner-app/SKILL.md`
  (panel runs `hermes chat -s planner-app`). Verbs: add, done/undone, delete, move, rename,
  reschedule, setkind, note, link, priority, assign, newlist, renamelist, browse, orderlists,
  deletelist. `delete` archives and `deletelist` is refused unless
  `hermes.allowsAgentDeletion` is on (Settings ▸ Agent safety).
- `Services/UpdatesSync.swift` — every 60 s: `reports/index.json` pages → `AgentReport`
  (re-saved on hash change); each `ReportReply` appended once to
  `~/DigitalWorkforce/replies/replies.jsonl`.
- `Services/AppointmentAgent.swift` — answers appointment comments via
  `~/DigitalWorkforce/bin/answer-appointment-comment.sh` (Atlas); the answer is appended to
  the item's notes so it syncs to the iPhone.
- Also: `WhatsAppReminders` (daily digests), `PowerSettings` (pmset wake schedule),
  `AppearanceController` (`appearanceMode`; ⇧⌘D toggle), `AgentRoster` (`~/.claude/agents`),
  `AgentChat` (`~/DigitalWorkforce/bin/chat-agent.py`).

## Build / run / test

```bash
xcodegen generate
# Debug build
xcodebuild -project PlannerApp.xcodeproj -scheme PlannerAppMac -configuration Debug \
  -derivedDataPath build/mac-dev -allowProvisioningUpdates build
open build/mac-dev/Build/Products/Debug/Planner.app --args -debugSidebar calendar -appearanceMode light
```

- DEBUG launch args: `-debugSidebar <SidebarItem rawValue>` (e.g. `calendar`, `jobs`,
  `updates`, `settings`), `-debugList <list name>`; `-appearanceMode light|dark|system` sets
  the AppStorage default via the argument domain.
- Standalone tests (no simulator): run line is at the top of `scripts/test-capture-edits.swift`
  and `scripts/test-follow-up-actions.swift`. UI tests are iOS-only.
- Store: non-sandboxed (sandbox removed so the panel can spawn agent CLIs), so SwiftData lives
  at `~/Library/Application Support/default.store`.

## Install and release

- `./scripts/build-macos-dmg.sh` → `dist/Planner-<MARKETING_VERSION>.dmg`: Release build signed
  with Developer ID (profile "PlannerAppMac Developer ID", `PlannerAppMacDevID.entitlements`),
  DMG signed, notarized with the ASC API key, stapled. Timestamp errors → just rerun.
- Plain `xcodebuild build` injects `get-task-allow` and notarization fails; the script passes
  `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`. Use the script for anything distributed.
- Install locally: `ditto build/mac-dmg/Build/Products/Release/Planner.app /Applications/Planner.app`
  (quit Planner first). Opening Planner always launches `/Applications/Planner.app`, so a new
  build does nothing until copied there. Afterwards `pgrep -fl MacOS/Planner` must show only
  `/Applications`. Stray registered copies (DerivedData, `build/`) make LaunchServices open
  the wrong one — trash them.
- GitHub release (`gh release`, tags `vX.Y`): the asset must be named exactly `Planner.dmg`
  (README links `releases/latest/download/Planner.dmg`), so copy/rename the dist file first.

## Gotchas

- **Live data in dev.** All entitlements except `PlannerAppMacDev.entitlements` pin
  `icloud-container-environment = Production`; every Debug build reads/writes the LIVE
  CloudKit data shared with the App Store iPhone app.
- **SwiftData model change ⇒ CloudKit schema first.** Every new/renamed field must exist in
  Production before any build that writes it ships; otherwise exports hit CKError
  partialFailure (2) and the export queue wedges permanently (iPhone↔Mac stop syncing).
  1. Init the Development schema (the iOS simulator can't — no iCloud account):
     ```bash
     xcodebuild -project PlannerApp.xcodeproj -scheme PlannerAppMac -configuration Debug \
       -derivedDataPath build/mac-schema -allowProvisioningUpdates \
       CODE_SIGN_ENTITLEMENTS=PlannerAppMac/PlannerAppMacDev.entitlements build
     script -q /dev/null build/mac-schema/Build/Products/Debug/Planner.app/Contents/MacOS/Planner -initCloudKitSchema
     ```
     (PTY needed or stdout is lost; look for `CK-SCHEMA: SUCCESS`; the run uses an in-memory
     store and exits. If it times out, `killall cloudd` and retry.)
  2. CloudKit Console → Deploy Schema Changes Dev → Production, before shipping. Adding the
     `CD_<field>` by hand in the Console also works.
  - Fields must have defaults / be optional (CloudKit rule). Small data can live in `notes`
    instead (see `MeetingLink`, `AppointmentComments`) to avoid a schema change.
- **Diagnose sync:**
  `sqlite3 ~/Library/Application\ Support/default.store "SELECT ZCLOUDKITEVENTTYPE, ZSUCCEEDED, ZERRORCODE FROM ANSCKEVENT ORDER BY ZSTARTEDAT DESC LIMIT 10;"`
  (type 0 setup, 1 import, 2 export). Cloud is the source of truth: fix a wedged mirror by
  quitting Planner and moving `default.store*` aside; it re-imports on launch.
- **Agents change data only through the file inbox:** `"<workspace>/planner" 'add?title=…&date=yyyy-MM-dd HH:mm'`
  (drops into `inbox/`, answer in `outbox/`). Not `open planner://` — LaunchServices may
  route it to a stale copy, and bursts drop events. `HermesBridge.agentsInstructions` is the
  doc agents see; keep it in sync with the verbs.
- Ordering: `ManualOrder` over `sortOrder` (0 = never placed, sorts last); pinned first via
  `isPinned`; to-do priority is `priorityRaw` (`PlannerPriority`, High/Critical auto-pin).
  Collapsed sidebar lists are device-local (`collapsedLists`): build the rows passed to
  `ListHierarchy.applyMove` with the same `collapsed:` set the sidebar shows, or indices misalign.
