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
- Mac overrides `CURRENT_PROJECT_VERSION` (currently "54") separately from the iOS base value;
  `MARKETING_VERSION` is shared.
- SwiftTerm is pinned `exactVersion: 1.11.2` — 1.12+ needs the Xcode Metal toolchain. Don't bump.

## Architecture

- `App/PlannerMacApp.swift` — `@main`; schema `[PlannerItem, PlannerList, AgentReport,
  ReportReply]`, `cloudKitDatabase: .automatic`, local/in-memory fallback. Starts
  `UpdatesSync` + `AppointmentAgent`; app delegate applies appearance and calls
  `HermesBridge.prepareWorkspace()`. Closing the window does not quit.
- `Views/MacRootView.swift` — `NavigationSplitView`; sidebar sections Strategy (Goals, Ideas), Tasks
  (To-Do, Pinned), Schedule (Today, Appointments — grouped by day, absorbed Upcoming — and
  Calendar), Content (Pages, Updates), Agents (Agent Jobs = `jobs`, plus a "Hermes Desktop" button (`HermesDesktop.open`: activates/launches
  `com.nousresearch.hermes`; the old embedded Hermes Dashboard pane was removed)), My Lists, Browse
  (Archive), Support. `SidebarItem` keeps `.scheduled`/`.todos` for persisted state only. User lists (`ListHierarchy`) + Digital Workforce staff.
- Panes: `MacPlannerPane` (items + capture bar; on Goals and Ideas the items area is
  `MacResearchPagesView`: one tab per item, the selected one's page rendered in the pane through an
  embedded `AgentBrowser`, so Reply boxes work and links open in the panel), `MacCalendarPane`, `MacUpdatesPane`,
  `MacSchedulePane` (workforce LaunchAgents `com.alfred.workforce.*`, Hermes/OpenClaw cron),
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
  deletelist. `add …&kind=page` upserts by title within the list; `done` refuses pages. At
  launch `PlannerKind.migrateContentToPages` turns "… Overview" to-dos with a page link into
  pages and restores pages checked off on old iPhone builds. `delete` archives and `deletelist` is refused unless
  `hermes.allowsAgentDeletion` is on (Settings ▸ Agent safety).
- `Services/UpdatesSync.swift` — every 60 s: `reports/index.json` pages → `AgentReport`
  (re-saved on hash change; off the main thread in its own `ModelContext`, since it reads every
  report file and stored HTML); each `ReportReply` appended once to
  `~/DigitalWorkforce/replies/replies.jsonl`.
- `Services/AppointmentAgent.swift` — answers appointment comments via
  `~/DigitalWorkforce/bin/answer-appointment-comment.sh` (Atlas); the answer is appended to
  the item's notes so it syncs to the iPhone.
- `Services/ItemResearcher.swift` — goals and ideas without a page get researched (right after
  adding, and every 60 s for ones from agents or the iPhone; max 2 at once; once each, a failed
  run waits for "Research Again"; a page linked during a run stays unless Research Again asked for
  a new one). Runs `~/DigitalWorkforce/bin/research-item.sh` (not in this
  repo): Nova, with web + a few read-only files only since web pages are untrusted, prints
  markdown with the same sections for both kinds (Review, Market research, Competitor analysis,
  Features, Recommendations, Strategy, Steps to implement, Caveats and risks, Sources); `research-clean.py` rejects incomplete pages and neutralises raw HTML;
  `publish-reports.py` renders it as `reports/<date>-nova-<kind>-<id8>.html`, so it gets the house
  style, Reply on each card and reaches the iPhone through Updates. The link goes on the item's
  `Page:` notes line. Log: `~/DigitalWorkforce/logs/<date>-nova-research.log`. The capture bar on
  Goals and Ideas files through `ItemResearcher.add`, not `PlannerCommand`. **A launch on live
  data starts real research on any goal without a page:** for UI checks pass
  `-researchScript /nonexistent` (DEBUG), which turns it off.
- `Services/ATOStatus.swift` — folders under the `ATO PROJECTS` list are coloured by application
  status: successful green, ongoing brown, rejected red, none plain. Kept per Mac in UserDefaults by
  list id (no schema change, no client names in this public repo). Set from the folder's ATO Status
  menu or `planner://atostatus?list=…&status=…`; the snapshot carries `atoStatus`.
- `Services/MeetingOpener.swift` — "Join meeting" opens Chromium browsers with `--new-window`:
  a plain URL open lands in the browser's last window, possibly on another Space, and looks
  like nothing happened.
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
  and `scripts/test-follow-up-actions.swift`; `scripts/test-item-researcher.swift` covers research
  with an in-memory store and a fake script. UI tests are iOS-only.
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
  Sidebar expand state is device-local and stores the *expanded* lists (`expandedLists`;
  everything else is collapsed, so newly synced lists start shut; launch clears it). Chevrons
  and row clicks are an accordion — opening a list folds its open siblings. Build the rows passed to
  `ListHierarchy.applyMove` with the same `collapsed:` set the sidebar shows, or indices misalign.
