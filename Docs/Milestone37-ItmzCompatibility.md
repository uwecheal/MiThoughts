# Milestone 37: iThoughts (.itmz) compatibility

Goal: MyThoughts opens, edits and saves iThoughts `.itmz` maps without losing data,
using our own clean-room implementation of the file format (no iThoughts code or resources).
Format reference: [`ITMZ_FORMAT.md`](ITMZ_FORMAT.md) (derived from 195 real maps).

| Step | Scope | Status |
|---|---|---|
| 37A | `ItmzKit`: ZIP, order-preserving XML DOM, iThoughts-identical serializer, `ItmzDocument` load/apply/save, XCTests | **done** (21 tests) |
| 37B | `IThoughtsImportService` on ItmzKit: layout, folded state, notes, links, task fields, markers, summaries, floating topics | **done** |
| 37C | Topic colour (+ inherited colour, coloured branch lines), 13 shapes, text size, boundaries, topic images, Markdown titles, relationship lines (curve/straight/elbow, arrows/dots, dashed, colour, label); same rendering in PDF/PNG/print | **done** |
| 37D | Export any map as `.itmz` (File ▸ Export as iThoughts, ⇧⌘E) | **done** |
| 37E | Open `.itmz` directly (File ▸ Open, Finder double-click), edit, Save writes back in place; untouched data preserved, backup of the previous file in `~/Library/Application Support/MyThoughts/iThoughts Backups` | **done** |
| 37F | App Store readiness: bundle ID, App Sandbox + user-selected files entitlement, privacy manifest | planned |

### Verified (2026-11-17, all 195 sample maps)

* open → save without edits: `mapdata.xml` byte-identical, every other archive entry identical;
* edit (title, colour, shape, new child, delete leaf, new relationship) → save → reopen: all edits present, positions kept;
* export without the original file (new `.itmz`) → reopen: same topics, fields, images, relationships, summaries, floating topics.

### Editing in MyThoughts

* Right-click a selected topic: **Colour**, **Shape**, **Text Size**, **Add/Remove Boundary**, **Image ▸ Add/Replace/Remove**, **Add Relationship...**, **Relationships ▸ Edit/Delete**.
* **Insert ▸ Relationship** (⇧⌘R): with two topics selected connects them, with one selected click the other end (Esc cancels).
* Click a relationship line to select it (Delete removes, Return edits); double-click opens the editor.

### Still kept-but-not-drawn

Groups, callouts, numbering, auto-sorting, sub-map layouts and `style.xml` level styles are preserved in the file but not rendered or edited yet.

## Code layout

```
ItmzKit/                         Swift package (Foundation + Compression only)
  Package.swift
  Sources/ItmzKit/
    ItmzZip.swift                ZIP read/write (stored + deflate), CRC-32
    ItmzXML.swift                ElementTree-style DOM, parser, iThoughts-style serializer
    ItmzDocument.swift           ItmzDocument (the DOM is the model), ItmzTopicNode, ItmzFormat
    ItmzLinks.swift              link normalization (www.…, mailto, …)
  Tests/ItmzKitTests/            XCTests (opt-in run over real maps)
MyThoughts/Utilities/IThoughtsImportService.swift   .itmz -> CanvasNode/Connection/Summary/Relationship
MyThoughts/Utilities/ItmzExportService.swift        CanvasNode... -> .itmz (in place via ItmzEditingSession, or new)
MyThoughts/Views/TopicStyleRendering.swift          colours, shapes, images, relationship + boundary drawing
```

The four `ItmzKit/Sources/ItmzKit/*.swift` files are **also compiled directly into the
MyThoughts app target** (Xcode group "ItmzKit"), so the app has no package dependency.
Keep ItmzKit free of app types (no SwiftUI, no `CanvasNode`) so it stays testable on its own.

## Build and test

1. Open `MyThoughts.xcodeproj`, build (⌘B), run (⌘R).
2. Import via the "Import iThoughts .itmz" button (canvas toolbar menu) and pick e.g. `~/Desktop/iThoughts-main/Help/Help.itmz`.
   The status message lists the topic count and anything not imported yet (relationships,
   images, colors – those come in 37C).
3. Format-layer tests, from Terminal:

   ```bash
   cd ItmzKit
   swift test                                              # unit tests
   ITMZ_SAMPLES=~/Desktop/iThoughts-main swift test        # + byte-identical round trip of every real map
   ```

   Or open `ItmzKit/Package.swift` in Xcode and press ⌘U.

## Import mapping (37B)

| iThoughts | MyThoughts |
|---|---|
| `position` (centre relative to parent centre) | `x, y` (absolute top-left), shifted so the map starts at (80, 80) |
| `text`, `note` | `title`, `body` (Markdown kept as-is) |
| `link` | `links[0]` (`www.x` → `http://www.x`, `a@b.c` → `mailto:`) |
| `folded="1"` | `isCollapsed` |
| `floating="1"` | separate root (no parent line), like in iThoughts |
| `icon1`/`icon2` | `marker` where an equivalent exists (idea, tick, tickbox, alert, question, star, flags, p0–p9) |
| `task-progress` (101 = done), `task-start`, `task-due`, `task-priority`, `task-effort`, `cost`, `cost-type="2"` | `progress`/`completedAt`, `startDate`, `dueDate`, `priority`, `effort`, `cost`, `rollupEnabled` |
| `summary1`/`summary2` | `CanvasSummary` |
| topic `uuid` | node `id` (kept, so 37E can write changes back to the same topics) |

Box sizes are estimated (iThoughts stores no heights); constants were tuned so that
visible-topic overlaps across the 195 sample maps drop from 1,372 to 176 pairs.

## Milestone 38A: Outline formats (Markdown, OPML, FreeMind)

`MyThoughts/Utilities/OutlineFormatService.swift`, a Swift port of itmz-studio's exporters plus matching importers. It works on any map, not only opened `.itmz` files.

* **Export**: File ▸ Export Outline ▸ Markdown / OPML / FreeMind (.mm). Topic images are copied to `<name>.assets/` next to Markdown and FreeMind files.
  * Markdown: levels 1–2 become headings and deeper topics nested bullets. Markers become emoji, links, task info and notes are kept, and relationships are listed at the end. A note that contains its own headings or lists is written as a `>` quote so it is not read back as topics.
  * OPML 2.0: `_note` and `url` attributes, plus `_itmz_color`, `_itmz_icon1`, `_itmz_folded` and `_itmz_task_progress`.
  * FreeMind/Freeplane: colours, folding, left/right side, icons, notes (HTML), links, images, and relationships as `arrowlink`.
* **Import**: File ▸ Open accepts `.opml`, `.md`/`.markdown` and `.mm`. They open as a new untitled map laid out as a tree.

Verified on all 195 sample maps (export, then import, then compare in pre-order):

| Format | Lossless | What is compared |
|---|---|---|
| OPML | 195/195 | titles, notes, links, colours |
| FreeMind | 195/195 | titles, links, colours, relationships |
| Markdown | 183/195 | titles |

The 12 Markdown cases are limits of Markdown itself: titles containing blank lines or `[1]: url` reference definitions, and a level-2 topic literally named "Relationships".

## Milestone 38B: Task management (iThoughts-style)

Code: `MyThoughts/Views/TaskManagement.swift` and the two-way sync in `Utilities/AppleIntegrationService.swift`.

* **Resources**: each topic has a list of assignees, saved to and read from the iThoughts `resources` attribute (and to OPML/Markdown).
* **Quick actions**: menu bar **Task**, or right-click a topic ▸ Task. They apply to every selected topic and can be undone.

  | Action | Shortcut |
  |---|---|
  | Mark as Done / Not Done | ⌃⌘D |
  | Progress +25% / −25% | ⌃⌘= / ⌃⌘- |
  | Priority High / Medium / Low / None | ⌃⌘1 / ⌃⌘2 / ⌃⌘3 / ⌃⌘0 |
  | Due Today (18:00) | ⌃⌘T |
  | Show Task List | ⌥⌘T |
  | Hide/Show Completed Tasks | ⌃⌘H |
  | Sync with Reminders & Calendar | ⌃⌘S |

  The Due Date submenu also offers Tomorrow, Next Week and Clear Dates, and the Resources submenu assigns names already used in the map.
* **Canvas badges**: a progress ring, a due date (red when overdue, orange when due today), priority (`!`, `!!`, `!!!`) and `@resources`, shown only on topics that have that data. Completed topics are struck through and dimmed. Each badge can be switched off in the Canvas popover. Settings saved by older versions (which showed "0%" on every topic) are migrated with the badges switched on.
* **Hide Completed Tasks**: hides a completed task together with its branch, like iThoughts.
* **Task list** (⌥⌘T or the Tasks button):
  * Filters: All, Overdue, Today, 7 Days, No Date; by resource or unassigned; show or hide completed.
  * Sort by due date, priority or map order. Tasks show their path in the map and an overall progress bar.
  * A checkbox ticks a task done; clicking a row jumps to the topic.
  * "Add n to Reminders" creates Apple Reminders for the open tasks shown that are not linked yet.
* **Two-way Reminders/Calendar sync**: a 3-way merge against the values agreed at the last sync, so each side's changes are detected.
  * When both sides changed a field: Apple wins for completion, dates and priority (usually changed on the iPhone); the map wins for title and notes.
  * If the Apple item was deleted, the link is removed.
  * Runs from the menu or task list, and automatically when MyThoughts becomes active (at most once a minute, only if items are linked; switchable).

Verified: 22 logic checks (actions, due status, filters, sorting, settings migration, saving); all 195 sample maps still save byte-identical, and editing resources, priority and progress round-trips through `.itmz` on all of them. In the app: task list, jump to topic, badges and ticking done from the list. Sync was **not** run against the real Reminders/Calendar data.
