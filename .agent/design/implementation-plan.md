# Implementation Plan

The MVP is delivered in three phases. Each phase builds on the previous one and is independently testable.

## Phased delivery

### Phase 1: Headless app + core engine

Ship `OKDisk.app` with a menu bar icon only (no GUI windows) and the full `OKDiskCore` engine. The app hosts the engine in-process and exposes an XPC listener. E2e tests start a test harness process (same `EngineHost` code) and connect via XPC.

Build the pure core engine first:

- Destination config reader/writer for `destinations.json`.
- Destination store initialization at arbitrary folder roots.
- Append-only JSONL writer/replayer.
- In-memory state model.
- Folder identity and path safety.
- Rsync-style mirror backup into `tree/`.
- Restore from `tree/`.
- Verification and repair.
- Crash safety (self-correcting mirror).
- XPC listener inside the app.

Why first: this unlocks unit/integration/e2e tests without the CLI or GUI. The core reliability is proven before any UI work.

### Phase 2: CLI

Ship `okdiskctl` — the operator and e2e test driver. It is always an XPC client that connects to the running app (or a test harness for e2e tests) via `OKDiskServiceProtocol`.

- Attach/list destinations.
- Add/list folders.
- Backup/restore/verify commands.
- JSON output.
- `--config` test isolation.
- Fault-injection flags for crash safety tests.

Why second: the CLI becomes the main regression/e2e test driver and enables full MVP operation without GUI.

### Phase 3: GUI

Ship the SwiftUI management windows inside `OKDisk.app`.

- Menu bar status and actions.
- Destination/folder management windows.
- Backup Now, restore, verify, conflict UX.
- Permission onboarding.

Why third: GUI is a thin layer over the already-tested engine. It should not block core reliability.

See individual plans for details:

1. [Core + Service](./implementation-plan-core-service.md) — storage engine, metadata replay, backup/restore, verification, reconciliation, XPC listener.
2. [CLI](./implementation-plan-cli.md) — `okdiskctl` for setup, backup, restore, verify, and e2e automation.
3. [GUI](./implementation-plan-gui.md) — SwiftUI menu bar app and management windows.

Testing is defined separately in [Testing Strategy](./testing-strategy.md).

## MVP acceptance criteria

- A source folder can be manually backed up to the configured replica count using destination folders. Files are rsync-mirrored into `tree/`.
- Incremental backup detects adds, modifies, deletes, and renames via diff against `tree/`.
- A disconnected/crashing run does not corrupt the latest completed backup. `tree/` changes from incomplete runs are self-correcting on the next run's diff.
- Connected destination log mismatches block mutations until explicit user confirmation.
- Confirmed reconciliation updates connected destinations to the latest healthy state.
- Full folder, subfolder, and single-file restore work from latest completed state.
- Files restore from `tree/` content directly.
- Deletions are propagated to online replicas immediately (files removed from `tree/`).
- Verification can identify stale, missing, or corrupt replica data in `tree/`.
- CLI e2e tests cover backup/restore/verify/crash/reconcile flows.
- The app has no web view and operates as native macOS UI plus in-process engine.
