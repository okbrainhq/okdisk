# Core + Engine Implementation Plan

This plan builds the reliable backup engine (`OKDiskCore`) and the app-side engine host with XPC listener. The core must work against ordinary folders as destinations.

## Part 1: SwiftPM scaffold

Deliverables:

- `OKDiskCore` target.
- `OKDiskApp` target (menu bar app that hosts the engine).
- Shared model types for folders, destinations, operations, metadata events, and errors.
- Test targets for unit and integration tests.
- Scripts: `build.sh`, `test.sh`.

Acceptance:

- Package builds from a clean checkout.
- Unit test target runs with one empty smoke test.
- No GUI dependency is imported by `OKDiskCore`.

## Part 2: Local destination config

Deliverables:

- `DestinationConfigStore` that reads/writes `destinations.json`.
- Atomic write using temp file + fsync + rename.
- Config path resolution for prod/dev/test.
- `OKDISK_DESTINATIONS_CONFIG` override.
- Local config lock.

Acceptance:

- Config stores only `destination_roots`.
- Duplicate paths are normalized and rejected.
- Tests can create isolated configs in temp directories.
- Corrupt config returns a clear error without touching destination logs.

## Part 3: Destination store abstraction

Deliverables:

- `DestinationRoot` validator.
- Store initializer for `okdisk.store.json`, `okdisk.metadata.jsonl`, `data/`, and `tmp/`.
- Store identity loading by `store_id`.
- Destination root lock file.
- Free-space/writability checks where available.

Acceptance:

- Any writable folder can be attached as a destination.
- Store initialization is idempotent.
- A configured missing folder is reported offline.
- External disk/APFS/encryption checks are optional status/warnings, not core requirements.

## Part 4: Metadata engine

Deliverables:

- Strongly typed metadata events:
  - `folder.upsert`
  - `folder.remove`
  - `sync_run.start`
  - `sync_run.end`
  - `state.reconcile`
- JSONL append writer with fsync support.
- JSONL replay reader.
- Replay state builder (folder configs, sync runs).
- Tree walker that enumerates `tree/` to build the file index on demand.
- Compaction writer.

Acceptance:

- Partial last line is ignored.
- Corrupt records are ignored/reportable without stopping replay.
- Files are not in the log; `tree/` is the source of truth and is walked on demand.
- Compaction preserves replay output exactly.
- `sync_run_seq` comes from connected destination logs.

## Part 5: In-memory state and reconciliation

Deliverables:

- `StateLoader` that loads all connected destinations from config.
- Cross-destination comparison.
- Latest healthy candidate selection.
- Conflict model for UI/CLI.
- Confirmed reconciliation operation.

Acceptance:

- Matching logs merge into one in-memory state.
- One stale destination blocks mutations.
- Reconcile requires explicit confirmation flag/request.
- Reconcile copies missing metadata and re-mirrors missing files, then appends `state.reconcile`.
- No automatic update happens without confirmation.

## Part 6: Folder management core

Deliverables:

- Folder ID generation from `hostname + source_path`.
- Add/update/remove folder operations.
- Path normalization.
- Excluded pattern support.
- Replica count validation.

Acceptance:

- Adding same folder on same host updates/rejects predictably.
- Same path on different hostname produces different `folder_id` in tests.
- Folder config is written to every connected destination log.
- Folder config is rebuilt after process restart by replaying logs.

## Part 7: Backup engine

Deliverables:

- Source scanner.
- Manifest diff (compare source snapshot to `tree/` walk).
- Replica destination selection.
- Rsync-style mirror into `tree/` (compare by size/mtime/inode, copy changed, delete removed, no log events).
- Directory and symlink support (mirrored into `tree/`, not logged).
- Bounded parallel file copy (2-4 concurrent per destination).
- Progress reporting hooks.
- Fault injection points for tests.

Acceptance:

- First backup succeeds to two temp destination folders.
- Incremental add/modify/delete cycles update `tree/` to match source.
- Crash before `sync_run.end` leaves `tree/` with partial changes that the next run corrects via diff.
- Metadata/control events are appended to every connected destination (folder config, sync runs only).
- Payloads are present only on selected replica destinations' `tree/`.

## Part 8: Restore engine

Deliverables:

- Restore latest full folder (walks `tree/` on a healthy replica).
- Restore subfolder.
- Restore single file.
- Restore plan preview.
- Collision report.
- Safe path handling.
- Size/hash verification during restore (recompute when deep verify).

Acceptance:

- Restored tree matches source after multiple backup cycles.
- Files restore from `tree/` content directly.
- Restore cannot write outside selected destination via path traversal.
- Overwrite requires explicit confirmation.

## Part 9: Verification and repair

Deliverables:

- Quick verification.
- Deep verification.
- Startup tmp cleanup.
- Missing/corrupt `tree/` entry detection.
- `tree/` drift detection (compare against source or healthy replica).
- Log mismatch detection.
- Repair from healthy replica (re-mirror missing/changed files).

Acceptance:

- Manual deletion of one replica's `tree/` entry is detected.
- Healthy second replica can repair the missing/corrupt one (re-mirror).
- Missing all replicas returns unrecoverable error.
- Repair never silently deletes questionable data.

## Part 10: App engine host + XPC listener

Deliverables:

- `OKDiskApp` menu bar app that starts the engine on launch.
- `OperationCoordinator` actor (serializes mutating jobs on background threads). This is the single serialization point for all callers — GUI and CLI alike.
- XPC listener inside the app process (`com.okdisk.service.xpc`).
- `OKDiskServiceProtocol` implementation — the single API surface used by both the GUI (in-process) and the CLI (via XPC).
- Status/progress polling via `getOperation`.
- Menu bar icon showing status (idle, backing up, attention needed).
- `TestHarness` target — starts the same `EngineHost` (engine + XPC listener) with a test config, for e2e tests without launching the full app.

Acceptance:

- App launches and starts the engine + XPC listener.
- E2e tests start a test harness process and connect the CLI via XPC.
- App can attach destinations, add folder, run backup, restore, verify.
- Restarting the app rebuilds state from destination logs.
- UI thread is never blocked by engine operations.
- GUI and CLI use the same `OKDiskServiceProtocol` — no caller bypasses the protocol.

## Core done criteria

- Unit and integration tests pass.
- E2e tests run against a test harness via XPC.
- Core backup/restore works without real disks.
- No local durable source folder config exists outside destination logs.
- Only `destinations.json` stores local destination directories.
