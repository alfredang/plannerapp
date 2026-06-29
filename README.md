# Planner — AI To-Do & Planner for iOS

A native iOS app for managing **to-dos and appointments by voice or touch**. Speak naturally —
*"Lunch with Sam tomorrow at 1pm"* — and on-device intelligence turns it into a scheduled
appointment; *"Buy groceries"* becomes a to-do. Appointments appear in a built-in calendar,
checked items auto-archive, and everything syncs to your personal iCloud.

![Planner — home screen](screenshot.png)

## Features

- ✅ **To-dos & appointments in one list** — add either from a single, smart form.
- 🎙️ **Voice capture** — tap the mic, speak, and native iOS speech-to-text transcribes it.
- 🧠 **On-device "AI" parsing** — detects dates/times, classifies task vs. appointment, and
  cleans up the title automatically (no network, fully private).
- 📅 **Built-in calendar** — appointments show on a graphical month calendar with per-day and
  upcoming lists.
- 📥 **Auto-archive** — checking off an item moves it to the Archive automatically; uncheck to
  restore.
- ☁️ **iCloud sync** — SwiftData + CloudKit mirrors your data to your private iCloud database
  across all your devices.
- 💬 **Feedback & About** — house-style tabs (WhatsApp feedback, developer info, version).

## Tech Stack

![Swift](https://img.shields.io/badge/Swift-5-FA7343?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-iOS%2017+-0071E3?logo=apple&logoColor=white)
![SwiftData](https://img.shields.io/badge/SwiftData-CloudKit-1B72E8?logo=icloud&logoColor=white)
![Speech](https://img.shields.io/badge/Speech-on--device-5856D6?logo=apple&logoColor=white)
![XcodeGen](https://img.shields.io/badge/XcodeGen-project.yml-2C2C2C)

- **UI:** SwiftUI, Human Interface Guidelines, SF Symbols, Dynamic Type, dark-mode theming.
- **Persistence & sync:** SwiftData with automatic CloudKit mirroring (private database).
- **Voice:** `SFSpeechRecognizer` + `AVAudioEngine` (prefers on-device recognition).
- **Intelligence:** `NSDataDetector` + `NaturalLanguage` for date extraction and classification
  (the `SmartParser.parse(_:)` entry point is provider-agnostic and can be swapped for an LLM).
- **Project:** generated from `project.yml` via [XcodeGen](https://github.com/yonik0/XcodeGen).

## Architecture

```
PlannerApp/
├── App/        PlannerApp.swift        — @main, SwiftData + CloudKit container
├── Models/     PlannerItem.swift       — single CloudKit-safe model (task | appointment)
├── Services/   SpeechRecognizer.swift  — native speech-to-text
│               SmartParser.swift       — date/time + intent parsing ("AI")
├── Theme/      Theme.swift             — central color tokens (auto dark mode)
└── Views/      MainTabView, TodoListView, CalendarView, ArchiveView,
                AddItemView, VoiceCaptureView, ItemRow, FeedbackView, AboutView
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
