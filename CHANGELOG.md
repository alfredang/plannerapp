# Changelog

## [3.1] — 2026-11-14

- Swipe an appointment to the left in the Calendar, in the month view or the list, and tap Delete to remove it from Planner

## [3.0] — 2026-11-12

- Planner no longer adds your classes to your calendars. Classes and their Google Meet links come only from the training system, so each class shows once, with its own Meet link
- Meetings copied into your Google Calendar keep their original Google Meet link. Google no longer swaps in a new link or emails you that the link was updated
- On Mac, your project folders now sit directly under Projects in the sidebar

## [2.9] — 2026-11-08

- Open a list on your iPhone or iPad and its pages, such as a client overview or the All Client Projects board, are shown first; tap one to read it, with the same content you see on your Mac
- Updates now has three tabs: Morning Brief, Updates (the Business Brief and the weekly summaries: strategy, projects, AI news) and Logs, so the briefs you act on aren't buried among routine agent logs
- The calendar colours each appointment by how it went: completed ones blue, missed ones red, and Singapore public holidays stand out

## [2.8] — 2026-11-06

- Goals, ideas and pages you keep in Planner on your Mac no longer appear as to-dos on your iPhone, and goal dates no longer set off reminders
- The duplicate check now only compares items in the same list, so each client's own copy of a document is left alone

## [2.7] — 2026-11-01

- A date-only appointment now shows as one day in your Google and other calendars (it used to cover the next day too), and two copies of the same appointment in one calendar are tidied into one

## [2.6] — 2026-10-30

- New appointments by chat: tap + and paste a screenshot of an email or invite, pick one from Photos, or just say or type it. Apple Intelligence on your iPhone reads it and drafts the appointment — title, date and time, place and meeting link — for you to check and add
- Say "add this to appointment" with a screenshot and it's added straight away; follow-ups like "make it 4pm" or "ends at 5pm" change the draft, and the classic form is one tap away
- Appointments added this way go to your ticked calendars and to Planner on your Mac like any other
- Calendar sync now also copies the appointments you already had before turning it on, not just new ones
- Turning sync on no longer ticks a calendar for you: tick the ones you want (for example your personal and work Google calendars), so nothing lands in a calendar you didn't choose
- Days you've booked as a holiday (an appointment titled "Holiday …") are shaded light green in the calendar, so time off stands out at a glance

## [2.5] — 2026-10-29

- Two-way calendar sync: turn on Settings ▸ Calendar sync and tick the calendars to keep in step, for example your personal and your work Google calendars. Every Planner appointment is added to each of them, and their events appear in Planner as appointments
- An event added in one ticked calendar is copied to the others, so every calendar shows your whole schedule
- Sync runs on its own when you open the app, whenever a calendar changes, and every couple of minutes while Planner is open; Sync Now runs it straight away
- A meeting moved or renamed in Google is updated in Planner and in your other calendars, and changes made in Planner go to all of them; invites from other people are never changed, and declined or cancelled events are skipped
- Your iPhone and Mac link to the same events, so you don't get duplicate copies

## [2.4] — 2026-10-20

- "Did this happen?" on a past appointment now has Cancelled and Rescheduled buttons next to Yes, it happened
- Cancelled crosses the appointment out and stops asking; you can undo it
- Rescheduled lets you pick the new date and time, moves the appointment (and its calendar event), and notes where it moved from
- Calendar: new refresh button, and pull down anywhere on the calendar to sync with iCloud; the month title shows when the iPhone last synced
- Updates and Morning Brief: pull down or tap the new refresh button to sync with iCloud; replies made on your Mac now show under each card, and a brief re-published on the Mac reloads on its own

## [2.3] — 2026-10-18

- To-do priorities now have their own colours — Critical red, High orange, Medium blue, Low green — on the flag, the badge and in the priority menu, with a tick on the current level
- Once you've replied to "Did this happen?" on a past appointment, it shows as Replied instead of asking again
- Answers from your Digital Workforce agent (Atlas, on the Mac) now appear right under your comment on the appointment, so you can see the next step on your iPhone

## [2.2] — 2026-10-16

- Update appointments by voice or text: say or type "move the Claude exam to 8pm" or "postpone UOB training to Friday" and the existing appointment is changed, instead of a new one being added
- A time alone keeps the day, and a day alone keeps the time
- Changes you make on iPhone now reach the Mac and your other devices straight away, even if you lock the phone right after
- Reply / comment on a past appointment now opens a comment box right under it, instead of the edit form; your comments show on the appointment and sync to your other devices

## [2.0] — 2026-10-11

- New Updates tab: read your Digital Workforce reports from the Mac and reply to any card right from the iPhone (syncs through iCloud)
- Past appointments you haven't ticked now ask "Did this happen?" with one-tap Yes, it happened / Reply buttons, instead of calling them missed

## [1.9] — 2026-10-10

- Choose the first day of the week for the calendar in Settings: Monday (the new default), Sunday or Saturday
- Sub-lists now start collapsed in My Lists, so your top-level lists fit on one screen; tap a chevron to open one
- Calendar keeps past appointments: checked ones show as Completed, unchecked ones as Missed (in red); tap any appointment to open it and add comments in its notes

## [1.7] — 2026-10-08

- New Calendar: a month view with each day's appointments written right into the day, plus a List view of every appointment; swipe to change month
- Reminder is now Upcoming, broken down by date — Today, Tomorrow and each day after, with anything overdue on top
- Today's appointments alert: a morning summary of the day's appointments (8 am, adjustable) and an alert just before each one starts
- Alerts now also show while Planner is open
- A fresh red app icon
- Singapore public holidays marked on the calendar
- To-Do priorities: mark a to-do Critical, High, Medium or Low; to-dos sort by priority, and Critical and High are pinned automatically
- Meeting links for virtual appointments: paste a Google Meet, Zoom or Teams link and tap Join on the appointment (links already in the notes are picked up too)
- A priority flag on every to-do row to change its priority in one tap
- Choose your look in Settings: Light, Dark or System, and an accent colour (Indigo, Red, Blue, Green, Orange, Purple, Pink or Teal)

## [Unreleased] — Mac

- Built-in browser next to the agent terminal: agents' daily HTML reports (with a Reports list), links clicked in the terminal, and an agent `browse` command
- Schedule: every scheduled background job in one place — Digital Workforce agents, Hermes and OpenClaw cron — with next run, last run and status; Run Now for agent jobs
- The agent terminal can start Claude Code, Codex, Hermes or OpenClaw (or a plain shell); scroll back through a Claude Code or OpenClaw conversation with the mouse wheel
- Agents can reorder lists (`orderlists`); the agent snapshot lists them in sidebar order
- Calendar week starts on Monday by default (Settings ▸ Calendar); sub-lists start collapsed
- Opens at login, and a "Keep running with the lid closed" switch (Settings ▸ Run in background)
- Fixed: Claude started inside the panel ran as a nested child of whatever session launched Planner (old version, wrong settings)
- Fixed: a hidden duplicate terminal kept running behind the visible one

- Upcoming (was Reminders), broken down by date
- A fresh red app icon
- Singapore public holidays marked on the calendar
- To-Do priorities (Critical / High / Medium / Low), set from a flag on each row; Critical and High are pinned automatically, and the Hermes agent can set them too
- Meeting links on virtual appointments with a Join button; included in the WhatsApp digest
- Calendar: a month grid with every appointment written into its day, plus a List view of all appointments; double-click a day to add one; ‹ › arrows change month
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
