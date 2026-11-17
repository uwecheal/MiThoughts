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
