# Tertiary Planner for iPhone/iPad (PlannerApp target)

AI to-do and appointment planner on the App Store (app id **6785397240**, bundle id
`com.tertiaryinfotech.plannerapp`, team `GU9WTSTX9M`, iOS 17+, iPhone + iPad). SwiftData +
CloudKit sync with the Mac edition; Mac notes are in `../PlannerAppMac/CLAUDE.md`.

## Project layout and code sharing

- XcodeGen: `project.yml` is the source of truth; `PlannerApp.xcodeproj/` is generated and
  gitignored. Run `xcodegen generate` after adding/removing files or changing settings.
- Everything under `PlannerApp/` builds into the iOS target. The Mac target **also** compiles
  all of `Models/`, `Services/`, `Theme/`, `Assets.xcassets` and these views: `ItemRow`,
  `FollowUpActionsView`, `AddItemView`, `ListsManagerView`, `ArchiveView`, `FeedbackView`,
  `AboutView`, `RemindersSettingsView`. Changes there must still build for macOS: keep
  UIKit-only code behind `#if os(iOS)` and check the Mac build too.
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` live in `project.yml` `settings.base`
  (currently 2.7 / 43). The Mac target overrides its own build number.

## Architecture

- `App/PlannerApp.swift` — `@main`; schema `[PlannerItem, PlannerList, AgentReport,
  ReportReply]` with `cloudKitDatabase: .automatic` (local fallback). Saves the context on
  `.background` so edits reach iCloud before suspension; re-arms alerts on `.active`.
- Models: `PlannerItem` (task | appointment via `kindRaw`; `date`, `isDone`, `isArchived`,
  `sortOrder`, `isPinned`, `assignedTo`, `priorityRaw`, `calendarEventID`), `PlannerList`
  (`parent`/`children` sub-lists, `sortOrder`, `isPinned`), `AgentReport` + `ReportReply`
  (Digital Workforce reports uploaded by the Mac, replies from either device).
  Helpers: `ManualOrder` (drag order; `sortOrder` 0 = never placed, sorts last),
  `ListHierarchy` (sub-list outline + drag-to-nest), `DaySections`, `MeetingLink` and
  `AppointmentComments` (both stored inside `notes`, no extra CloudKit fields),
  `FollowUpActions`, `SingaporeHolidays`.
- Services: `PlannerCommand` (capture-bar command router — add vs. reschedule/rename/etc.;
  `keywordFallback` when no Apple Intelligence), `IntentAssistant` (FoundationModels, iOS 26+),
  `AppointmentExtractor` (pasted invite / screenshot text → `AppointmentDraft`; the model picks
  date phrases that must appear verbatim, `SmartParser` makes the date; end time, location and
  meeting link ride in `notes`),
  `SmartParser` (deterministic dates), `ReminderScheduler` + `TodayAlerts` (local
  notifications), `CalendarSync` (two-way EventKit sync with every ticked calendar, e.g. Google angchewhoe@ + angch@: each appointment is copied to all of them, events from any come into Planner; `CalendarAutoSync` runs it at launch, on `EKEventStoreChanged` and every 2 min; links by `calendarItemExternalIdentifier` in `calendarEventID` + a `Planner id:` line in each copy's notes + per-device `calendar.links`; per-device agreed-state in UserDefaults decides push vs pull; same-marker duplicate copies are removed), `CloudSyncStatus` (`syncNow`, last sync),
  `DuplicateAudit`, `ModelUndoSupport`, `SpeechRecognizer`, `WeekStart`.
- UI (`Views/MainTabView.swift`): bottom tabs Planner, Calendar, Archive, Settings, Feedback,
  About. `TodoListView` (Planner) has top tabs **Updates | Tasks | Appointments**, opens on
  Updates (`UpdatesView`), and shows the chatbot capture bar (type or dictate) on Tasks and
  Appointments. `CalendarView` is month grid + list with a refresh button and pull-to-refresh
  (`CloudSyncStatus.syncNow`); Planner and Updates are `.refreshable` too.
  **+ on Appointments and on the Calendar opens `AppointmentChatView`** (iOS-only, not in the
  Mac target): paste/pick a screenshot (Vision OCR on-device), dictate or type → draft card →
  Add / Edit (the form, prefilled via `ParsedEntry.notes`/`meetingLink`). "add this to
  appointment" (`AppointmentExtractor.isConfirmation`) adds it; said before the paste, it adds
  as soon as the draft is ready. To-do + still opens `AddItemView`.
  `AssistantChatView` is not currently shown.
- AppStorage keys worth knowing: `ownerName` (who "me" is for smart views), `iosAppearance`,
  `accentTheme` (changing it rebuilds tabs via `.id`), `calendar.weekStart`, `calendar.mode`,
  `calendar.syncEnabled`, `calendar.syncCalendarIDs` (legacy `calendar.targetCalendarID`), `calendar.importEvents`, `collapsedLists` (device-local).

## Build / run / test

```bash
xcodegen generate && open PlannerApp.xcodeproj      # iPhone 17 Pro simulator
xcodebuild test -project PlannerApp.xcodeproj -scheme PlannerApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'   # PlannerAppUITests
```

- Standalone regression tests (no simulator): the run line is at the top of
  `scripts/test-capture-edits.swift`, `scripts/test-follow-up-actions.swift` and
  `scripts/test-appointment-extractor.swift` (the last runs the deterministic path unless the
  binary can reach Apple Intelligence).
- DEBUG launch args: `-seedSampleData` (in-memory store, demo data, no permission prompts —
  used by UI tests/screenshots), `-openPlanner`, `-openCalendar`, `-openSettings`,
  `-openUpcoming`, `-openAppointments`, `-openTasks`, `-dumpReminders`, `-dumpTodayAlerts`.
- Device install (phone must be **unlocked**; get the id from `xcrun devicectl list devices`):
  ```bash
  xcodebuild -project PlannerApp.xcodeproj -scheme PlannerApp -configuration Debug \
    -destination 'id=<device UDID>' -derivedDataPath build/device -allowProvisioningUpdates build
  xcrun devicectl device install app --device <id> build/device/Build/Products/Debug-iphoneos/PlannerApp.app
  ```
  Install is an upgrade and keeps the data container. Shortcut:
  `bash ~/.claude/skills/ios-auto-release/scripts/install_on_device.sh`.

## Release (App Store)

- Use the ASC API skills, not the browser: `asc-api-submit` (attach build, submit, verify
  WAITING_FOR_REVIEW) and `app-store-submission` (screenshots/metadata/privacy). The
  project-local `.claude/skills/ios-auto-release` has `upload_binary.sh` + `ci_submit.py`
  (run them with `zsh`; macOS bash 3.2 fails to parse `upload_binary.sh`).
- Build numbers: bump `CURRENT_PROJECT_VERSION` in `project.yml` by one for every upload
  (single integer across versions: 2.2 → 34, 2.3 → 35, 2.4 → 36/37). ASC only enforces
  uniqueness. Commit as `chore: vX.Y build N — submitted for App Store review`.
- Add a `## [X.Y] — date` section at the top of `CHANGELOG.md` first; it becomes What's New.
- Check the version state before uploading: error 90062/90186 ("train closed") means that
  version is already approved, so bump `MARKETING_VERSION`.
- If `xcrun altool` hangs or fails, upload with `xcodebuild -exportArchive` (destination
  upload, manual signing, profile "PlannerApp App Store", `-authenticationKeyPath` …).
  After swapping builds, re-check that the version's attached build is the new one.

## Gotchas

- **Dev builds hit LIVE data.** `PlannerApp.entitlements` pins
  `icloud-container-environment = Production`, so simulator/device Debug builds sync with
  real user data, the same CloudKit env as the App Store app and the Mac.
- **SwiftData model change ⇒ CloudKit schema first.** A field missing from Production makes
  exports fail with CKError partialFailure and wedges the export queue permanently
  (iPhone↔Mac stop syncing). Initialize the Development schema with the **Mac** Debug build
  (`-initCloudKitSchema`, recipe in `../PlannerAppMac/CLAUDE.md`; the simulator path in
  `PlannerApp.swift` fails without an iCloud account), then deploy Dev → Production in the
  CloudKit Console **before shipping** (or add the `CD_<field>` by hand there). All
  properties need defaults or must be optional; relationships optional. Prefer storing small
  extras in `notes` like `MeetingLink`/`AppointmentComments` to avoid schema changes.
- **Diagnose sync** on the Mac store (same cloud data):
  `sqlite3 ~/Library/Application\ Support/default.store "SELECT ZCLOUDKITEVENTTYPE, ZSUCCEEDED, ZERRORCODE FROM ANSCKEVENT ORDER BY ZSTARTEDAT DESC LIMIT 10;"`
  (0 setup, 1 import, 2 export). Cloud is the source of truth: a wedged iPhone mirror is fixed by
  `xcrun devicectl device uninstall app --device <id> com.tertiaryinfotech.plannerapp`, then
  reinstall (a plain install keeps the stale container).
- `ItemRow`'s `detailsRow` is `.accessibilityElement(children: .combine)` with a tap that opens
  the edit form. Buttons or fields inside it get swallowed, so interactive controls go
  outside it (as the "Did this happen?" block does).
- Ordering: always sort through `ManualOrder` (`sortedPinnedFirst` for pinned-first). To-dos
  sort pinned → priority → manual; `setPriority` auto-pins High/Critical.
- Capture-bar edits must go through `PlannerCommand.handle` + `commit` (explicit save for an
  immediate CloudKit export). Add-only drafting created duplicates before v2.2.
