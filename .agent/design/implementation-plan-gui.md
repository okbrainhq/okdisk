# GUI Implementation Plan

> **Phase 3 deliverable.** The GUI ships after the headless app + core engine (Phase 1) and CLI (Phase 2) are proven. It is a thin SwiftUI layer over the already-tested engine.

The GUI is a native SwiftUI menu bar app. It calls the `OKDiskCore` engine directly (same process, no IPC). It should stay thin and rely on the engine for correctness.

## Part 1: App scaffold (Phase 1 headless → Phase 3 full UI)

The app scaffold is built in Phase 1 as a headless menu bar app. In Phase 3, the SwiftUI windows are added.

Phase 1 deliverables (already done):

- `OKDiskApp` SwiftPM executable/app bundle target.
- `MenuBarExtra` entry point with status icon only.
- Engine host that starts `OKDiskCore` + XPC listener on launch.
- Dev/prod bundle IDs.
- App state object.
- Basic status polling.

Phase 3 deliverables:

- SwiftUI windows for Settings, Folders, Destinations, Restore, Activity Log.
- View models for destinations, folders, operations, restore, and conflicts.
- Stable accessibility identifiers for testable controls.

Acceptance:

- `./scripts/run.sh` opens the dev menu bar app with full UI.
- Menu shows service status and management windows.
- App can be launched with test config environment for UI tests.

## Part 2: Service client and models

Deliverables:

- Direct `OKDiskServiceProtocol` access (same process — no XPC transport needed, but the GUI calls the same protocol methods the CLI uses). The GUI must not bypass `OKDiskServiceProtocol` or touch engine internals directly.
- Mock protocol implementation for previews/UI tests.
- View models for destinations, folders, operations, restore, and conflicts.
- Stable accessibility identifiers for testable controls.

Acceptance:

- UI can run against real `OKDiskServiceProtocol` implementation or mock/test protocol.
- Engine errors are shown clearly.
- UI tests can identify controls without fragile text matching.

## Part 3: Destination window

Deliverables:

- List configured destination folders.
- Add destination via `NSOpenPanel`.
- Remove destination path from local config with confirmation.
- Show store ID, online/offline, writable/log status.
- Show production warnings for external disk/APFS/encryption when available.

Acceptance:

- User can attach a normal folder as a destination.
- Destination appears after engine reload.
- Removing destination does not delete backup data.
- UI does not require a real external disk for MVP flow.

## Part 4: Folder window

Deliverables:

- Add source folder via `NSOpenPanel`.
- Show hostname + source path identity.
- Configure replica count.
- Remove/tombstone folder.
- Show last backup and health from replayed state.

Acceptance:

- Adding a folder appends `folder.upsert` through the engine.
- Folder list survives app restart by replaying destination logs.
- Duplicate folder handling is clear.

## Part 5: Backup and activity UX

Deliverables:

- **Backup Now** menu action for all folders.
- Per-folder backup button.
- Operation progress view.
- Recent operation summary view.
- Permission/failure guidance.

Acceptance:

- User can manually run backup from menu bar.
- UI shows success/failure and operation summary.
- If logs mismatch, backup button is blocked and conflict prompt appears.

## Part 6: Restore UX

Deliverables:

- Restore window.
- Folder/subfolder/file selection.
- Restore destination picker.
- Collision preview.
- Restore progress and summary.

Acceptance:

- User can restore full folder, subfolder, or single file.
- UI never overwrites without explicit confirmation.
- Restore output is visible in Finder/open button.

## Part 7: Verification and conflict UX

Deliverables:

- Verify Backups menu action.
- Quick/deep verification selection.
- Missing/corrupt replica report.
- Conflict warning screen.
- Explicit **Update Destinations to Latest** confirmation flow.

Acceptance:

- Mismatched destination logs produce a clear warning.
- User sees stale/diverged destinations and candidate latest state.
- Reconcile action requires an explicit confirmation button.
- UI calls engine reconciliation API; it does not write logs directly.

## Part 8: Minimal UI tests

Deliverables:

- `OKDiskUITests` target.
- Launch app with temporary config path.
- Fixture `OKDiskServiceProtocol` or test-mode protocol via test harness.
- Accessibility identifiers on important controls.

Initial tests:

- Open menu bar and status.
- Attach destination folder.
- Add source folder.
- Trigger Backup Now and see success.
- Restore one file to temp output.
- Show conflict warning for mismatch fixture.

Acceptance:

- UI tests pass without external disks.
- UI tests are stable enough for regular local runs.
- Core reliability remains covered by CLI e2e tests, not UI tests.

## GUI done criteria

- Native menu bar app supports the full MVP path.
- No web view is required.
- GUI can manage ordinary folder destinations.
- GUI correctly blocks on conflicts and asks for confirmation.
- Minimal UI interaction tests cover critical paths.
