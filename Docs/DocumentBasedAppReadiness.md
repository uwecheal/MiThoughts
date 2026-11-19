# MiThoughts Document-Based App Readiness Review

Milestone 36A is a review-only milestone. This report audits the current lightweight file management system and evaluates readiness for a future macOS `DocumentGroup` conversion. No app behavior should be changed as part of this milestone.

## Current Architecture Summary

MiThoughts is currently a single-window SwiftUI app with document-like behavior managed manually inside `InfiniteCanvasView`.

The current persistence and file system are split across three layers:

| Layer | Current implementation | Purpose |
| --- | --- | --- |
| Local autosave | `NodeStore` writes `Application Support/MiThoughts/nodes.json` | Restores the last working map between launches |
| Explicit `.mythoughts` files | `MiThoughtsDocumentService` encodes/decodes `MiThoughtsDocument` | Save, Save As, Open, full-map export/import, branch export/import |
| UserDefaults settings | `CanvasAppearance`, `NotePanelSettings`, `OutlineSettings`, `RecentFilesStore` | Appearance defaults, note panel state, outline visibility, recent files |

The app already has a stable document payload model:

- `MiThoughtsDocument`
- `formatVersion`
- `documentType`
- `nodes`
- `connections`
- `canvasSettings`
- `notePanelSettings`
- `metadata`

That model is a good foundation for a future document wrapper, but the surrounding state ownership is not yet separated enough for a low-risk `DocumentGroup` conversion.

## Current File Flow

### Local Autosave

`InfiniteCanvasView.init()` loads `NodeStore.loadDocument()` from the app support JSON file. This creates the current in-memory `nodes` and `connections`.

`saveNodes(markDirty:)` calls:

- `refreshDerivedData()`
- `NodeStore.saveDocument(nodes:connections:)`
- `markDirty()` when requested

This means local autosave is used for nearly every map mutation, independent of whether the user has explicitly saved a `.mythoughts` file.

### Explicit Save

`saveCurrentFile()` writes to `currentFileURL` if one exists. If no file URL exists, it falls back to `saveCurrentFileAs()`.

`saveCurrentMap(to:shouldUpdateCurrentFile:)` validates the map, exports a full `MiThoughtsDocument`, updates `currentFileURL`, adds the file to `RecentFilesStore`, clears `isDirty`, sets `lastSavedAt`, and updates the window title.

### Save As

`saveCurrentFileAs()` presents `NSSavePanel`, enforces the `.mythoughts` extension, and delegates to `saveCurrentMap`.

### Open

`openMiThoughtsFile()` asks about unsaved changes, presents `NSOpenPanel`, imports a `.mythoughts` file, rejects branch documents for Open, then calls `applyOpenedDocument`.

`applyOpenedDocument` repairs the imported map, replaces in-memory nodes and connections, applies document canvas/note-panel settings, clears transient UI state, selects a root node, centers it, sets `currentFileURL`, updates recent files, clears dirty state, writes local autosave, saves UserDefaults settings, and hides the Start Screen.

### New Map

`newMap()` asks about unsaved changes, clears nodes/connections, clears selection and editing state, resets file URL and history, writes an empty local autosave with `markDirty: false`, hides the Start Screen, and updates the title.

### New From Template

`showTemplateChooser()` asks about unsaved changes and opens the template chooser.

`applyTemplate()` generates a new map using `BuiltInTemplateFactory`, repairs it, replaces nodes/connections, clears transient state, clears file URL and history, optionally enables quadrants, selects and centers the template root, writes local autosave with `markDirty: false`, and hides the Start Screen.

### Recent Files

`RecentFilesStore` stores up to 10 paths in UserDefaults. `openRecentFile(_:)` removes missing files, asks about unsaved changes, and opens the file through the same full-map path.

### Start Screen

`isShowingStartScreen` is view state in `InfiniteCanvasView`. It appears on launch when the autosaved working map is empty. It can also be shown from File > Show Start Screen.

The Start Screen reuses existing commands:

- New Blank Map -> `newMap()`
- New From Template -> `showTemplateChooser()`
- Open Existing Map -> `openMiThoughtsFile()`
- Recent Files -> `openRecentFile(_:)`
- Continue Last Working Map -> hide Start Screen

### Import `.mythoughts`

`importMiThoughtsFile()` is separate from Open.

- If the document is `.branch`, it imports into the current map using branch paste/remap logic.
- If the document is `.fullMap`, it asks for confirmation and then `applyPendingImport()` replaces the current map.

Full-map import is undoable through a snapshot before replacement. It does not currently set `currentFileURL`, because Import is treated differently from Open.

### Import iThoughts `.itmz`

`importIThoughtsFile()` parses the external archive through `IThoughtsImportService`, asks for confirmation, repairs the result, replaces the current map, records undo, saves local autosave, and centers the imported root.

This is a conversion/import operation, not an Open operation.

### Export `.mythoughts`

`exportMiThoughtsFile()` writes the current full map to a chosen `.mythoughts` file but does not update `currentFileURL` or clear dirty state. This is correctly treated as export, not save.

### Export Selected Branch

`exportSelectedBranchFile()` collects selected top-level branches and descendants, sanitizes external Apple IDs, writes a `.mythoughts` document with `documentType = branch`, and does not change the current map file URL.

### PDF / PNG / Print

`exportMapAsPDF()`, `exportMapAsPNG()`, and `printMap()` use `MapExportRenderer` and `currentMapExportPayload()` to render visible map content. These actions do not mutate document data, update dirty state, or affect undo history.

## Document Data vs App / Session State

### Should Be Document Data

| Data | Current location | Future document ownership |
| --- | --- | --- |
| Nodes | `nodes` state, `CanvasNode` | Document |
| Connections | `connections` state, `CanvasConnection` | Document |
| Node title/body | `CanvasNode` | Document |
| Task fields | `CanvasNode` | Document |
| Cost/effort/rollup fields | `CanvasNode` | Document |
| Links | `CanvasNode.links` | Document |
| Markers | `CanvasNode.marker` | Document |
| Collapse state | `CanvasNode.isCollapsed` | Document |
| Parent IDs and sort order | `CanvasNode.parentID`, `sortIndex` | Document |
| Apple Reminder / Calendar IDs | `CanvasNode.appleReminderID`, `appleCalendarEventID` | Document, with clear caveats |
| Canvas appearance | `CanvasAppearance` | Prefer document if maps need unique appearance |
| Note panel settings | `NotePanelSettings` | Ambiguous; see risks |

### Should Be App / Session State

| Data | Current location | Future ownership |
| --- | --- | --- |
| Selected node IDs | `selectedNodeID`, `selectedNodeIDs` | Session/window state |
| Editing node ID | `editingNodeID` | Session/window state |
| Details panel node | `detailsNodeID` | Session/window state |
| Pan offset | `panOffset` | Session/window state unless explicitly saved as view state |
| Zoom scale | `zoomScale` | Session/window state unless explicitly saved as view state |
| Focus mode | `isFocusMode`, `focusedNodeID` | Session/window state |
| Search query/results | `searchQuery`, `searchResults` | Session/window state |
| Open panels/popovers | `isShowingSearchPanel`, `isShowingAppearancePopover`, `isShowingTemplateChooser` | Session/window state |
| Start Screen visibility | `isShowingStartScreen` | App/window state |
| Current file URL | `currentFileURL` | Document system responsibility after conversion |
| Dirty flag | `isDirty` | Document system responsibility after conversion |
| Recent files | `RecentFilesStore` | App-level state |
| Pending imports/alerts | `pendingImportDocument`, confirmation flags | Session/window state |
| Undo/redo stacks | `HistoryManager` | Per-document or per-window document controller |

## Risks Before DocumentGroup Conversion

### `currentFileURL` Ownership

`currentFileURL` is manually tracked in `InfiniteCanvasView`. A `DocumentGroup` app would expect the system document wrapper to own file identity. Keeping both systems could create conflicting save targets and incorrect window titles.

### Dirty State Ownership

`isDirty` is manually set by `saveNodes(markDirty:)`. A document-based app should use the document editing lifecycle instead. Current autosave writes can mark the map dirty while also saving to local autosave, which is conceptually different from unsaved file edits.

### Local Autosave vs Document Autosave

`NodeStore` always restores a single last working map. A document-based app should open specific file-backed documents, potentially many at once. The current single autosave file would conflict with multi-window documents unless it is redefined as crash recovery or removed from normal document state.

### Undo/Redo Scope

`HistoryManager` is view-local and snapshots `nodes` and `connections`. Future document undo should be per document, not app-global. External Apple creation also clears history in some paths, which needs explicit policy.

### Settings Ownership

`CanvasAppearance` and `NotePanelSettings` are both encoded into `.mythoughts` documents and also persisted in UserDefaults. This creates ambiguity:

- Are theme/grid/node-style settings per map?
- Are note panel width/visibility per app/window?
- What should win when a document is opened?

This should be resolved before conversion.

### Start Screen State

The Start Screen is currently overlaid inside `InfiniteCanvasView`. In a document-based app, a start screen is often an app-level or separate window concern, not document content. It should not become part of a document scene.

### Import vs Open Distinction

The distinction is currently correct but manual:

- Open sets `currentFileURL` and recent file state.
- Import replaces or merges content without changing file URL.
- Export writes data without changing file URL.

This distinction must be preserved in a document app. It is easy to accidentally make Import behave like Open during a refactor.

### Temporary UI State Coupled to Document State

`InfiniteCanvasView` owns document data and many transient UI flags. `DocumentGroup` conversion will be safer if a view model separates document content mutations from window UI state.

### Apple Reminder / Calendar IDs

Apple IDs are stored on nodes and exported/imported. They are local external references, not portable document data in the same way node titles are. They can become stale across machines. The app already clears them in branch export, which is good. Full document migration should decide whether keeping them is still correct.

### Branch Documents

`.mythoughts` supports `documentType = branch`. A `DocumentGroup` opener must not accidentally treat branch files as standalone full documents unless that is an intentional future behavior.

## Recommendation

Recommendation: **Convert later. Do not convert yet.**

The current lightweight file system is good enough for the current single-window prototype. It supports explicit Save, Save As, Open, Recent Files, Start Screen, import/export, autosave, and recovery well enough to continue feature work.

However, converting now would be risky because document data, app preferences, session state, undo ownership, autosave, and file identity are still tightly coupled inside `InfiniteCanvasView`.

The best next step is to clean document ownership boundaries first, without changing user behavior.

## Staged Migration Plan

### 36B: Clean Document Model

Create a focused model such as `MiThoughtsMapDocumentData` or refine `MiThoughtsDocument` so all real document fields are clearly owned by one type:

- nodes
- connections
- canvas appearance if per-document
- optional document metadata

Keep decoding backward-compatible.

### 36C: Separate App State From Document State

Introduce a lightweight view model or controller that separates:

- document content
- file identity
- dirty state
- UI/session state
- derived data

This should be done without changing visible behavior.

### 36D: Create Document Wrapper Type

Create a future-ready `FileDocument` or `ReferenceFileDocument` wrapper around the clean document model. Test encode/decode independently before wiring it into the app.

### 36E: Test Opening/Saving Through Document Wrapper

Add unit-style or utility-level tests for:

- current `.mythoughts` files
- older JSON files
- branch documents
- missing newer fields
- invalid or repairable structures

Do this before switching the app entry point.

### 36F: Optional DocumentGroup Conversion

Convert the app entry point to `DocumentGroup` only after the wrapper is stable. At this stage:

- system file identity replaces `currentFileURL`
- system document dirty state replaces manual `isDirty`
- manual Open/Save commands are revised or removed
- Start Screen becomes an app-level launcher, not document content

### 36G: Optional Multi-Window Support

Only after `DocumentGroup` is stable, consider multiple open maps. This requires per-document instances of:

- undo/redo
- selection state
- derived data
- focus/search state
- panels and window-specific UI state

## Required Cleanup Before Conversion

1. Decide whether `CanvasAppearance` is per-document, global app preference, or both with a clear precedence rule.
2. Decide whether `NotePanelSettings` belongs in the document or only in UserDefaults/window state.
3. Move save/open/import/export logic out of `InfiniteCanvasView` into a coordinator or document controller.
4. Keep `Open`, `Import`, `Export`, and `Save As` semantics separate and named clearly.
5. Resolve local autosave semantics:
   - keep as last-working-map recovery for non-document mode, or
   - replace with document autosave, or
   - make it explicit recovery state only.
6. Move dirty tracking away from generic `saveNodes()` so local autosave does not obscure explicit file save state.
7. Make undo ownership per document and decide whether appearance settings belong in undo.
8. Keep `documentType = branch` handling out of normal full-document open paths.
9. Audit Apple Reminder / Calendar IDs as local external references before enabling cross-device document workflows.
10. Add small tests or fixtures for document decoding and repair before any app entry-point refactor.

## Files Reviewed

| File | Relevance |
| --- | --- |
| `MiThoughts/Views/InfiniteCanvasView.swift` | Owns most document state, autosave, file commands, import/export, Start Screen, undo, and UI state |
| `MiThoughts/Utilities/NodeStore.swift` | Defines `.mythoughts` document model/service, autosave store, recent files, file commands |
| `MiThoughts/MiThoughtsApp.swift` | Defines current app scene and menu commands |
| `MiThoughts/Utilities/HistoryManager.swift` | Owns snapshot undo/redo model |
| `MiThoughts/Utilities/MapValidator.swift` | Validates and repairs document structure |
| `MiThoughts/Utilities/IThoughtsImportService.swift` | Converts external iThoughts files into map data |
| `MiThoughts/Utilities/MapExportRenderer.swift` | Handles PDF/PNG/print rendering without mutating document data |
| `MiThoughts/Utilities/BuiltInTemplateFactory.swift` | Generates new maps from templates |
| `MiThoughts/Views/StartScreenView.swift` | Provides lightweight launcher UI using existing file commands |
| `MiThoughts/Views/TemplateChooserView.swift` | Creates template maps through existing template flow |
| `MiThoughts/Models/CanvasNode.swift` | Primary document data model |
| `MiThoughts/Models/CanvasConnection.swift` | Connection document data model |

## Files Likely Affected In A Future Conversion

- `MiThoughts/MiThoughtsApp.swift`
- `MiThoughts/Views/InfiniteCanvasView.swift`
- `MiThoughts/Utilities/NodeStore.swift`
- `MiThoughts/Utilities/HistoryManager.swift`
- `MiThoughts/Utilities/MapValidator.swift`
- `MiThoughts/Views/StartScreenView.swift`
- `MiThoughts/Views/TemplateChooserView.swift`
- `MiThoughts/Utilities/BuiltInTemplateFactory.swift`
- `MiThoughts/Models/CanvasNode.swift`
- `MiThoughts/Models/CanvasConnection.swift`

## Final Assessment

MiThoughts is document-ready at the data-format level, but not yet document-ready at the app-architecture level.

The safest path is to keep the current lightweight file system for now and do a staged cleanup before any `DocumentGroup` conversion. The next best milestone is 36B: clean and centralize the document model while preserving all current behavior.
