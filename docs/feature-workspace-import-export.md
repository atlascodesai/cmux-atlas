# Feature: Workspace Import/Export

## Context
Users want to save and share workspace configurations (layout, panels, directories, scrollback) as files. The snapshot infrastructure already exists for session persistence — this feature exposes it as user-facing import/export via the workspace context menu.

## Design Decisions
- **File format**: JSON wrapped in a versioned `WorkspaceExportEnvelope` (version, timestamp, app version, workspace snapshot)
- **Extension**: `.cmuxworkspace` with custom UTType `com.cmux.workspace-export` conforming to `public.json`
- **Scrollback**: Included by default (already capped at 400K chars per terminal)
- **Scope**: Single workspace per file (multi-export deferred)
- **Import placement**: Inserted after the currently selected workspace, then selected
- **Path handling**: Keep absolute paths as-is — workspace restore already falls back to `~` for missing dirs
- **Entry points**: Workspace context menu plus File > Organizations (command palette can follow)
- **Errors**: `NSAlert` for import failures (corrupt data, version mismatch)

## Implementation

### 1. Export envelope + encode/decode (`Sources/SessionPersistence.swift`)
- Add `WorkspaceExportEnvelope` struct (Codable)
- Add `WorkspaceImportError` enum (LocalizedError)
- Add `WorkspaceExportStore` enum with `export()` → `Data?` and `importWorkspace(from:)` → `Result`
- Encoder uses `.sortedKeys, .prettyPrinted` for human-readable files

### 2. UTType declaration (`Resources/Info.plist`)
- Add `UTExportedTypeDeclarations` entry for `com.cmux.workspace-export`
- Add `CFBundleDocumentTypes` entry so macOS knows the app handles `.cmuxworkspace`

### 3. TabManager methods (`Sources/TabManager.swift`)
- `exportWorkspace(_ workspace: Workspace)` — snapshot → encode → NSSavePanel → write
- `importWorkspace(after: Workspace?)` — NSOpenPanel → read → decode → restore
- `restoreImportedWorkspace(_:after:)` — create Workspace, call restoreSessionSnapshot, wire ownership, insert in tabs, select
- Helper: `sanitizedFilename(_ workspace:) -> String`
- Helper: `showWorkspaceIOError(_ message:)`
- Add `import UniformTypeIdentifiers`

### 4. Context menu items (`Sources/ContentView.swift`)
- Add after the "Reveal in Finder" button (around line 10782):
  - Divider
  - "Export Workspace..." button → `tabManager.exportWorkspace(tab)`
  - "Import Workspace..." button → `tabManager.importWorkspace(after: tab)`
- All strings localized

### 5. Localization (`Resources/Localizable.xcstrings`)
- `contextMenu.exportWorkspace` / `contextMenu.importWorkspace`
- Error alert titles
- Japanese translations

## Existing Infrastructure to Reuse
- `SessionWorkspaceSnapshot` (SessionPersistence.swift:334) — already Codable
- `Workspace.sessionSnapshot(includeScrollback:)` (Workspace.swift:108) — creates snapshot
- `Workspace.restoreSessionSnapshot(_:)` (Workspace.swift:175) — restores from snapshot with ID remapping
- `SessionPersistenceStore` save/load pattern (SessionPersistence.swift:367)
- NSSavePanel pattern: BrowserPanel.swift:4518
- NSOpenPanel pattern: ContentView.swift:5363

## NOT in v1
- Command palette entries
- Multi-workspace export
- Finder double-click-to-import (needs AppDelegate wiring)
- Path rewriting for cross-machine portability
- Option to exclude scrollback

## Verification
1. Build with `./scripts/reload.sh --tag atlas-dev`
2. Right-click workspace → "Export Workspace..." → save file
3. Verify `.cmuxworkspace` file contains readable JSON with layout + panels
4. Right-click workspace → "Import Workspace..." → select the exported file
5. Verify new workspace appears with correct title, color, directory, and layout
