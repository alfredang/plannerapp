# Tertiary Planner — AI To-Do & Planner for iOS & macOS

A native iOS + macOS app for managing **to-dos and appointments by voice or touch**. Speak
naturally — *"Lunch with Sam tomorrow at 1pm"* — and on-device intelligence turns it into a
scheduled appointment; *"Buy groceries"* becomes a to-do. Organize items into your own lists
and sub-lists, pin what matters, drag everything into your own order, see appointments in a
built-in calendar — and it all syncs across your iPhone and Mac through your personal iCloud,
with full undo.

<a href="https://apps.apple.com/app/tertiary-planner/id6785397240">
  <img src="https://toolbox.marketingtools.apple.com/api/badges/download-on-the-app-store/black/en-us?releaseDate=1751500800" alt="Download on the App Store" height="54">
</a>
&nbsp;
<a href="https://github.com/alfredang/plannerapp/releases/latest/download/Planner.dmg">
  <img src="https://img.shields.io/badge/%EF%A3%BF%20Download%20for%20Mac-DMG-2C2C2C?style=for-the-badge" alt="Download for Mac (DMG)" height="54">
</a>

> **iPhone / iPad:** get it on the
> [App Store](https://apps.apple.com/app/tertiary-planner/id6785397240).
> **Mac:** [download the DMG](https://github.com/alfredang/plannerapp/releases/latest/download/Planner.dmg),
> open it, and drag **Planner** onto **Applications** — no App Store needed. Both apps sync
> through the same private iCloud database.

![Tertiary Planner — home screen](screenshot.png)

## Features

- 🗓️ **Appointments & To-Dos, each on its own tab** — clean, uncluttered pages; the app opens
  to Appointments, with To-Dos one tap away. Both filter by your lists and sub-lists.
- 💬 **Assistant everywhere** — a chatbot capture bar sits at the bottom of both tabs: tell it
  what you need, by text or voice, and it drafts a nicely worded entry and saves it instantly
  (with undo). The Chat tab holds full conversations.
- 🍎 **Apple Intelligence on-device** — on iOS 26+ devices with the system model available, the
  assistant uses Apple's FoundationModels framework to classify and word entries; everywhere
  else it falls back to the deterministic parser. Both paths are fully local.
- ✅ **To-dos & appointments in one list** — add either from a single, smart form.
- ✏️ **Tap to edit** — tap any item in the Planner or Calendar to fix a typo or change its
  title, notes, type, or date in the same form used to create it.
- 🎙️ **Voice capture** — tap the mic, speak, and native iOS speech-to-text transcribes it.
- 🧠 **On-device "AI" parsing** — detects dates/times, classifies task vs. appointment, and
  cleans up the title automatically (no network, fully private).
- 📅 **Built-in calendar** — appointments show on a graphical month calendar with per-day and
  upcoming lists.
- 📥 **Auto-archive** — checking off an item moves it to the Archive automatically; uncheck to
  restore.
- 🔔 **Reminders** — a heads-up notification before anything with a date is due: **3 days
  ahead by default**, switchable to 1 day or 1 week (or off) in the Reminders tab. Alerts are
  local to your device, re-armed whenever items change so iCloud edits from another device
  stay in sync, and never fire for something already past.
- 🗂 **Your own lists** — create, rename, and delete lists ("Work", "Groceries", …), file items
  into them, and browse them from the folder button. Tapping a folder opens it to show its
  to-dos and appointments (rename, pin and delete live in its context menu); the filter bar
  at the top of each tab keeps just the smart views — **To-Do, Pinned, Today**. Lists
  sync like everything else.
- ↕️ **Drag to rearrange** — hold and drag to-dos, appointments, and your lists into any order,
  on iPhone and Mac alike; your custom order syncs across devices via iCloud.
- 🗂️ **Sub-lists** — nest lists under a parent (e.g. each client under "Clients"): create one
  from a list's context menu, or drag a list into a group to nest it. A parent list shows its
  own items plus everything in its sub-lists. Synced like everything else.
- 🔽 **Collapse & expand** — fold a group shut with its chevron, or collapse/expand **every**
  list at once from the Mac sidebar's "My Lists" header or the Manage Lists toolbar on iPhone.
- 📌 **Pin to top** — tap the pin on any row (or swipe right on iPhone, right-click on Mac) to
  pin it; pinned entries float above the rest and sync across devices. A dedicated **Pinned**
  view right next to To-Do collects everything you've pinned.
- 👤 **Delegate with Assign to** — put someone's name on an item and it moves out of your
  way: **To-Do, Pinned and Today show only your own work** (unassigned, or assigned to
  you). Their items still show in full when you open their list. Set who "you" are in
  Settings ▸ Me on the Mac.
- ↩️ **Undo everywhere** — take back deletes, check-offs, edits, and drags: ⌘Z / Edit ▸ Undo
  on the Mac, the Undo toolbar button on iPhone.
- ☁️ **iCloud sync** — SwiftData + CloudKit mirrors your data to your private iCloud database
  across all your devices, iPhone and Mac alike.
- 🖥 **macOS desktop edition** — a two-column Mac app: smart categories and your lists in the
  sidebar (with a live iCloud sync-status indicator), and the item list with a chatbot-style
  capture bar (type or dictate) on the right.
  Distributed as a [DMG](https://github.com/alfredang/plannerapp/releases/latest/download/Planner.dmg);
  build it yourself with `./scripts/build-macos-dmg.sh`.
- 🤖 **Hermes agent terminal (Mac)** — a collapsible right-hand panel (⌥⌘T) embeds a real
  terminal ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)) that auto-starts the
  [Hermes Agent](https://hermes-agent.nousresearch.com) CLI when installed. Ask it in plain
  language — *"add buy milk tomorrow"*, *"move the n8n task to AI-LMS-TMS"*, *"mark it done"* —
  and it edits your planner through a local `planner://` command bridge, reading live state
  from an auto-maintained JSON snapshot. The panel docks beside the list (drag the divider to
  resize) and becomes a slide-over sheet on narrow windows.
  **The agent cannot delete your data by default:** `delete` archives the item instead
  (restorable from Archive) and deleting a list is refused outright, since that would orphan
  every item inside it. Opt in via Settings ▸ Agent safety ▸ "Allow agent to delete".
- 💬 **Feedback & About** — house-style tabs (WhatsApp feedback, developer info, version).

## Tech Stack

![Swift](https://img.shields.io/badge/Swift-5-FA7343?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-iOS%2017+-0071E3?logo=apple&logoColor=white)
![SwiftData](https://img.shields.io/badge/SwiftData-CloudKit-1B72E8?logo=icloud&logoColor=white)
![Speech](https://img.shields.io/badge/Speech-on--device-5856D6?logo=apple&logoColor=white)
![XcodeGen](https://img.shields.io/badge/XcodeGen-project.yml-2C2C2C)

- **UI:** SwiftUI, Human Interface Guidelines, SF Symbols, Dynamic Type, dark-mode theming.
- **Persistence & sync:** SwiftData with automatic CloudKit mirroring (private database).
- **Voice:** `SFSpeechRecognizer` + `AVAudioEngine` (prefers on-device recognition); the audio
  engine is created lazily so no microphone prompt appears until dictation is actually used.
- **Intelligence:** `IntentAssistant` uses Apple's on-device **FoundationModels** (Apple
  Intelligence, iOS 26+) for intent classification and title wording, falling back to
  `SmartParser` (`NSDataDetector` + `NaturalLanguage`). Dates always come from the
  deterministic parser so clock math never hallucinates.
- **Project:** generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Architecture

```
PlannerApp/                             — iOS app + code shared with the Mac target
├── App/        PlannerApp.swift        — @main, SwiftData + CloudKit container
├── Models/     PlannerItem.swift       — CloudKit-safe model (task | appointment)
│               PlannerList.swift       — user-created list (items kept on delete)
│               ChatMessage.swift       — assistant conversation turn (shared)
│               ManualOrder.swift       — synced drag-rearrange ordering helper
│               ListHierarchy.swift     — nested sub-list outline + drag-to-nest logic
├── Services/   IntentAssistant.swift   — on-device Apple Intelligence drafting (iOS/macOS 26+)
│               SmartParser.swift       — deterministic date/time + intent parsing
│               SpeechRecognizer.swift  — native speech-to-text (cross-platform)
│               ReminderScheduler.swift — local "N days before" alerts for dated items
│               ModelUndoSupport.swift  — system undo/redo for all SwiftData changes
├── Theme/      Theme.swift             — central color tokens (auto dark mode)
└── Views/      MainTabView, AssistantChatView, TodoListView, CalendarView,
                ArchiveView, AddItemView, ListsManagerView (+ ListDetailView),
                RemindersSettingsView, VoiceCaptureView, ItemRow, FeedbackView,
                AboutView

PlannerAppMac/                          — macOS desktop edition (DMG)
├── App/        PlannerMacApp.swift     — @main, same schema + iCloud container
├── Services/   HermesBridge.swift      — planner:// command scheme + JSON state snapshot
│                                         + AGENTS.md workspace for the Hermes agent
│               CloudSyncStatus.swift   — CloudKit account status for the sidebar badge
└── Views/      MacRootView.swift       — sidebar: smart categories + user lists + sync badge
                MacPlannerPane.swift    — item list + chatbot capture bar (text/voice)
                MacTerminalPanel.swift  — collapsible SwiftTerm panel auto-running hermes
                MacSettingsPane.swift   — settings: owner name, agent safety, terminal panel

scripts/build-macos-dmg.sh              — Release build → DMG (+ notarization when a
                                          Developer ID certificate is present)
```

## Getting Started

```bash
# Requirements: Xcode 16+ (iOS 17 SDK), XcodeGen (brew install xcodegen)
xcodegen generate
open PlannerApp.xcodeproj
```

Build & run on the **iPhone 17 Pro** simulator, or select your device.

### Enabling iCloud sync on a device

The default device build installs with **local storage**. To turn on iCloud sync:

1. In Xcode → **Settings → Accounts**, add your Apple ID (Apple Developer Program team).
2. Select the **PlannerApp** target → **Signing & Capabilities**; Xcode registers the
   **iCloud** + **Push Notifications** capabilities declared in `PlannerApp.entitlements`
   and creates the `iCloud.com.tertiaryinfotech.plannerapp` container.
3. Ensure `CODE_SIGN_ENTITLEMENTS` points at `PlannerApp/PlannerApp.entitlements` in `project.yml`,
   then rebuild.

## Permissions

The app requests **Microphone** and **Speech Recognition** access only when you first use voice
capture. Transcription prefers Apple's on-device engine where supported.

## Acknowledgements

Developed by **Tertiary Infotech Academy Pte Ltd** — [tertiaryinfotech.com](https://www.tertiaryinfotech.com)

---

🤖 Built with [Claude Code](https://claude.com/claude-code)
