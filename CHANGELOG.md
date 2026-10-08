# Changelog

## [1.7] — 2026-10-08

- New Calendar: a month view with each day's appointments written right into the day, plus a List view of every appointment; swipe to change month
- Reminder is now Upcoming, broken down by date — Today, Tomorrow and each day after, with anything overdue on top
- Today's appointments alert: a morning summary of the day's appointments (8 am, adjustable) and an alert just before each one starts
- Alerts now also show while Planner is open
- A fresh red app icon
- Singapore public holidays marked on the calendar
- To-Do priorities: mark a to-do Critical, High, Medium or Low; to-dos sort by priority, and Critical and High are pinned automatically
- Choose your look in Settings: Light, Dark or System, and an accent colour (Indigo, Red, Blue, Green, Orange, Purple, Pink or Teal)

## [Unreleased] — Mac

- Upcoming (was Reminders), broken down by date
- A fresh red app icon
- Singapore public holidays marked on the calendar
- Calendar: a month grid with every appointment written into its day, plus a List view of all appointments; double-click a day to add one
- Light / Dark toggle in the toolbar (⇧⌘D), and a default mode (System, Light or Dark) in Settings
- Daily WhatsApp reminders: today's appointments at 8 am and tomorrow's at 3 pm (times adjustable), sent through Hermes or opened in WhatsApp
- Fixed: appointments the Hermes agent was asked to add never appeared — the agent now always gets the Planner instructions, and its commands reach the open Planner window
- Fixed: titles the agent sent with `+` for spaces kept the plus signs; a date the agent got wrong is now rejected instead of silently dropped
- Fixed: a hidden second Hermes process could start alongside the visible one

## [1.6] — 2026-08-18

- A single Planner tab: To-Do and Appointment are now top tabs on one page
- To-Do has All Tasks and Pinned Tasks; Appointment has Today and Reminder
- A brighter look: the app now uses a clean light theme throughout
- See your iCloud sync status in Settings, with the time of the last sync
- Sync Now button and pull-to-refresh nudge iCloud whenever you want to be sure
- Delete a row with its trash button, or move it to another list from its menu

## [1.5] — 2026-07-27

- Tap a folder in Manage Lists to open it and see its to-dos and appointments
- Add items right inside a folder with the + button
- A simpler filter bar: All, Pinned, Today and Reminders; your lists live behind the folder button
- Reminders: get a notification before anything with a date is due — 3 days ahead by default, or 1 day or 1 week
- Duplicate check: the app spots the same title on the same day and offers to archive the extras
- Delete any row with its trash button, or move it to another list from its menu
- Items added inside someone's list are automatically assigned to that person
- Collapse or expand all your lists at once; sub-lists have a chevron on iPhone too
- To-Do, Pinned and Today show only your own work — items assigned to others appear in their lists
- New Settings tab: set your name and the reminder controls
- The capture bar saves your entry straight into the list — the new row is the confirmation, and Undo reverts it
- Fixed: items with no date are no longer turned into appointments
- Fixed: turning off "Set date & time" on an appointment moves it back to a to-do
- Fixed: with lists collapsed, deleting or dragging a list could affect the wrong one
## [1.4] — 2026-07-17

- Appointments and To-Dos now live on their own tabs — cleaner, faster to scan; each is
  filterable by your lists and sub-lists
- Chatbot capture bar on both tabs: type or dictate and the assistant drafts and saves
  the entry, with one-tap Undo; the Chat tab stays for full conversations
- Rearrange everything by hand: hold and drag to-dos, appointments, and your lists into
  the order you want
- Tap the pin on any row to pin it to the top; assign items to people with the new
  "Assign to" field
- New Pinned view: see everything you've pinned in one place (sidebar on Mac, chip on
  iPhone)
- Setting a date & time on a to-do turns it into an appointment automatically
- Sub-lists: nest lists under a parent (e.g. clients under "Clients") — create one from
  a list's menu, or drag a list into a group; a parent shows its own and its sub-lists' items,
  and can be collapsed in the Mac sidebar
- Pin to top: pin your most important to-dos (swipe right, or right-click on Mac) and
  lists — pinned entries float above the rest
- Undo: take back any change — deletes, check-offs, edits, and drags (⌘Z on Mac, the
  Undo button on iPhone)
- Your custom order, sub-lists, and pins sync across iPhone and Mac via iCloud
- Bug fixes and performance improvements

## [1.3] — 2026-07-15

- Your lists are now always visible as a chip bar on the Planner tab — tap a chip to
  filter, long-press to rename or delete a list
- Improved list syncing across your iPhone and Mac
- Bug fixes and performance improvements

## [1.3-mac] — 2026-07-15 (desktop only)

- Hermes agent terminal: collapsible right panel with a real terminal that auto-starts
  the Hermes CLI agent — tell it "add …", "move … to …", "mark … done" and it edits the
  todo list through the app's `planner://` command bridge (`HermesBridge`), reading live
  state from `planner-state.json` in its workspace
- Adaptive layout: the panel docks beside the list (drag the divider to resize) and
  becomes a slide-over sheet on narrow windows; ⌥⌘T or the toolbar button toggles it
- iCloud sync status indicator at the bottom of the sidebar
- Fixed: external `planner://` URL events no longer open a new window each time
- Note: the Mac app is no longer sandboxed (required to launch the user's hermes CLI);
  distribution is unchanged (Developer ID DMG, notarized)

## [1.2] — 2026-07-14

- Create your own lists — organize to-dos into lists you can create, rename, and delete
- Pick a list when adding or editing an item, and filter the planner by list
- Everything syncs across your devices with iCloud, including the new Mac desktop app

## [1.2-mac] — 2026-07-14 (desktop only)

- macOS desktop edition (`PlannerAppMac` target, packaged as a DMG via
  `scripts/build-macos-dmg.sh`): two-column layout — smart categories and
  your own lists in the sidebar with live counts; item list with a
  chatbot-style capture bar (type or dictate, the on-device assistant
  drafts and saves the entry) on the right; syncs with the iPhone app via
  the same iCloud Production container

## [1.1] — 2026-07-03

- Assistant chat: tap the conversation or swipe down to dismiss the keyboard

## [1.0] — 2026-07-03

- Initial release: AI to-do & planner with on-device Apple Intelligence assistant chat
