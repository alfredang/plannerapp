# Changelog

## [1.5] — 2026-07-18

- Tap a folder in Manage Lists to open it and see its to-dos and appointments — no more
  jumping straight to Rename (rename, pin and delete now live in the folder's menu)
- Add items right inside a folder with the ＋ button
- The filter bar is simpler: just All, Pinned, and Today; your lists live behind the
  folder button
- Turning off "Set date & time" on an appointment now works — it moves back to a to-do
- Reminders: get a heads-up notification before anything with a date is due — 3 days
  ahead by default, or choose 1 day or 1 week in the new Reminders settings
- "Scheduled" is now called "Reminders"
- Collapse or expand all your lists at once, on both iPhone and Mac; sub-lists now have
  a chevron on iPhone too
- Fixed: with lists collapsed, deleting or dragging a list could affect the wrong one
- Your lists stay yours: All Items, Pinned and Today now show only your own work —
  anything you've assigned to someone else appears in their list instead
- Fixed: items with no date are no longer turned into appointments
- Fixed: the assistant no longer adds words you didn't type to an item's title
- The assistant's Undo now asks before removing the entry it just saved

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
