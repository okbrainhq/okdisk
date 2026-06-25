# OKDisk Design Specification

This document is the single source of truth for the OKDisk design. Implementation plans, CLI plans, GUI plans, and testing strategy live in separate documents referenced at the end.

OKDisk is a native macOS, application-level backup system for personal folders. The production target is APFS-encrypted external SSDs, but the core treats every backup target as a normal destination folder so the same logic is easy to test end-to-end.

---

## 1. MVP scope

### In scope

- Native macOS menu bar app that hosts the backup engine in-process. Both the GUI and the CLI use the same `OKDiskServiceProtocol` interface — the GUI calls it directly (same process), the CLI connects via XPC.
- Developer/operator CLI for setup, backup, restore, verification, and e2e tests.
- Manual folder backup: user clicks **Backup Now** or runs the CLI.
- Full folder, subfolder, and single-file restore.
- Multiple destination folders, each treated as an independent replica store.
- Per-folder replica count.
- Folder identity based on `hostname + full source path` so future multi-host support is possible.
- Append-only JSONL metadata log at the root of each destination folder. The log records folder-level config and sync run history only. Individual files are NOT logged.
- Rsync-style mirror backup: all files are mirrored directly into `tree/` on each replica destination. `tree/` is the source of truth for file content.
- One local config file that stores only the destination directories.
- Engine working state rebuilt from destination logs (folder config, sync runs) and `tree/` walks (file index) into memory.
- Logic-heavy automated e2e testing using temporary source/destination folders.

### Out of scope for MVP

- Separate launchd service (the app hosts the engine directly).
- Web view or remote UI.
- NAS/network storage.
- Version history or snapshots.
- Content deduplication across files/folders.
- Large-file blob storage and pointer files (planned for V2).
- Continuous automatic sync from FSEvents.
- Hot-swap rebalancing while an operation is running.
- Cross-host conflict resolution.
- Depending on real external disks for e2e tests.

---

## 2. Phased delivery

| Phase | What ships | Purpose |
|-------|-----------|---------|
| **Phase 1: Headless app + core** | `OKDisk.app` (menu bar icon only, no windows) + `OKDiskCore` engine + XPC listener | Core reliability — backup, restore, verify, crash safety. E2e tests drive the engine via XPC through a test harness. |
| **Phase 2: CLI** | `okdiskctl` | Operator/test driver. Connects to running app (or test harness) via XPC. Full MVP without GUI. |
| **Phase 3: GUI** | SwiftUI windows inside `OKDisk.app` | Management UI — destinations, folders, backup now, restore, verify, conflicts. |

Both the GUI and the CLI use the same `OKDiskServiceProtocol` interface. The GUI calls the protocol implementation directly (same process, same object — no IPC overhead). The CLI calls the same protocol via XPC. The `OperationCoordinator` actor serializes all operations regardless of caller, so there is no risk of the GUI and CLI stepping on each other.

---

## 3. Architecture

### 3.1 High-level shape

OKDisk has two macOS executables/entry points:

1. `OKDisk.app` — menu bar app that hosts the `OKDiskCore` engine in-process and exposes an XPC listener. Both the GUI and the CLI are clients of the same `OKDiskServiceProtocol`. In the initial version the app is headless (no GUI windows); the SwiftUI UI is added in Phase 3.
2. `okdiskctl` — CLI that connects to the running app over XPC and calls `OKDiskServiceProtocol`.

There is no separate launchd service. The app process IS the service. When the app launches, it starts the engine and the XPC listener. When the app quits, the engine stops.

### 3.2 Why the app hosts the engine (no launchd)

- The app backs up the current user's files and needs the same access the user has.
- A menu bar app stays running in the background, so the engine is available whenever the app is open.
- One process, one binary — no launchd plist, no service lifecycle management, no service startup race conditions.
- Simpler testing — e2e tests start a test harness process that runs the same `EngineHost` (engine + XPC listener) with a test config; the CLI connects to it via XPC. No full app launch needed.
- If automatic scheduled backups are needed later, a lightweight launchd helper can be added without reworking the core.

### 3.3 Destination-folder abstraction

The MVP must not depend on real disk state. A backup target is a destination folder:

```text
/any/path/chosen/by/user/
  okdisk.store.json
  okdisk.metadata.jsonl
  data/
  tmp/
```

Production usage normally points destination folders at external APFS-encrypted SSDs, for example `/Volumes/Backup-A/OKDiskStore`. Tests can point them at temporary folders, for example `/tmp/okdisk-e2e/dest-a`.

Rules:

- Core logic talks to destination folders, not physical disks.
- Destination health means path exists, is writable, has a valid store identity, and has a readable append-only log.
- APFS/encryption checks are optional UI warnings for production safety, not requirements for the core e2e path.
- A destination is identified by `store_id` from `okdisk.store.json`, not by volume UUID or mount path.

### 3.4 Process responsibilities

#### OKDisk menu bar app

The app hosts the `OKDiskCore` engine and an XPC listener. In Phase 1 it shows only a menu bar icon (no windows). In Phase 3 it adds the full SwiftUI management UI.

Responsibilities:

- Start the `OKDiskCore` engine on launch.
- Start the XPC listener exposing `OKDiskServiceProtocol`.
- The GUI (Phase 3) calls the same `OKDiskServiceProtocol` implementation directly — it does not bypass the protocol or touch engine internals.
- Show global status in the menu bar: idle, backing up, restoring, verification needed, destination missing, permission issue, or log mismatch.
- (Phase 3) Add/remove destination folders through `NSOpenPanel`.
- (Phase 3) Add/remove source folders through `NSOpenPanel`.
- (Phase 3) Configure per-folder replica count.
- (Phase 3) Trigger **Backup Now**.
- (Phase 3) Open restore window and submit restore requests.
- (Phase 3) Show operation progress and recent logs.
- (Phase 3) Show mismatch warning and require explicit confirmation before reconciliation.
- (Phase 3) Onboard permissions, especially Full Disk Access when broad folder coverage is needed.

Implementation direction:

- SwiftUI `MenuBarExtra` for the menu bar.
- (Phase 3) SwiftUI windows for Settings, Folders, Destinations, Restore, Activity Log.
- The engine runs on background threads; the UI thread is never blocked.
- Keep UI models thin; use `OKDiskServiceProtocol` status as source of truth.
- The GUI must not bypass `OKDiskServiceProtocol` or touch engine internals directly.
- Do not make UI correctness a blocker for core reliability; most verification comes from core/CLI/e2e tests.

#### Engine (inside OKDisk.app)

The engine is `OKDiskCore` — a SwiftPM library embedded in the app process. It runs on background threads.

Responsibilities:

- Load `destinations.json` and validate each destination root.
- Initialize destination stores when attaching a new destination.
- Replay destination JSONL logs into an in-memory state model at startup and before mutations. The log yields folder configs and sync runs. Files are enumerated from `tree/` on demand.
- Detect log mismatches across connected destinations.
- Execute backup (rsync-style mirror into `tree/`), restore, verification, compaction, and reconciliation jobs.
- Emit progress/events to the UI and CLI.

Concurrency model:

- One top-level `OperationCoordinator` actor serializes mutating jobs.
- Only one backup, restore, verification-repair, compaction, or reconciliation runs at a time in MVP.
- Per-file copy work can use bounded concurrency, default 2-4 files per destination.
- Metadata append is serialized per destination.
- Cancellation is cooperative and leaves incomplete runs without `sync_run.end`.

#### okdiskctl CLI (Phase 2)

Responsibilities:

- Attach/list/remove destination folders in the local config file.
- Add/list/update source folders through the engine via XPC (`OKDiskServiceProtocol`).
- Run backup, restore, verify, reconcile, and compact.
- Print machine-readable JSON for e2e assertions.
- Support `--config <path>` so tests can run without touching the user's real config.
- The CLI is always an XPC client — it connects to the running app (or a test harness for e2e tests). There is no in-process mode.

### 3.5 IPC

The app exposes an XPC listener so the CLI can connect to the running app. The GUI does not use XPC transport — it calls the same `OKDiskServiceProtocol` implementation directly in-process. Both GUI and CLI use the identical protocol interface, so there is a single API surface and a single serialization point (`OperationCoordinator`).

XPC listener name:

```text
com.okdisk.service.xpc
```

Initial service commands:

```swift
protocol OKDiskServiceProtocol {
    func getStatus(reply: @escaping (ServiceStatus) -> Void)

    func listDestinations(reply: @escaping ([DestinationStatus]) -> Void)
    func attachDestination(_ request: AttachDestinationRequest, reply: @escaping (Result<DestinationStatus, ServiceError>) -> Void)
    func removeDestination(rootPath: String, reply: @escaping (Result<Void, ServiceError>) -> Void)

    func listFolders(reply: @escaping ([FolderConfig]) -> Void)
    func addFolder(_ request: AddFolderRequest, reply: @escaping (Result<FolderConfig, ServiceError>) -> Void)
    func updateFolder(_ request: UpdateFolderRequest, reply: @escaping (Result<FolderConfig, ServiceError>) -> Void)
    func removeFolder(folderID: String, reply: @escaping (Result<Void, ServiceError>) -> Void)

    func startBackup(folderID: String?, reply: @escaping (Result<OperationID, ServiceError>) -> Void)
    func startRestore(_ request: RestoreRequest, reply: @escaping (Result<OperationID, ServiceError>) -> Void)
    func startVerification(_ request: VerifyRequest, reply: @escaping (Result<OperationID, ServiceError>) -> Void)
    func getStateConflicts(reply: @escaping ([DestinationStateConflict]) -> Void)
    func confirmUpdateDestinationsToLatest(_ request: ReconcileRequest, reply: @escaping (Result<OperationID, ServiceError>) -> Void)
    func cancelOperation(_ operationID: OperationID, reply: @escaping (Result<Void, ServiceError>) -> Void)
    func getOperation(_ operationID: OperationID, reply: @escaping (OperationStatus?) -> Void)
}
```

Progress can be implemented first as polling with `getOperation`, then upgraded to streaming XPC callbacks.

State conflict commands are intentionally explicit. If connected destination logs disagree, the engine reports a blocked state to the UI/CLI; the UI/CLI must show the candidate latest state and request user confirmation before `confirmUpdateDestinationsToLatest` appends repair/reconcile records.

### 3.6 Locking and write ownership

Because both the app (via GUI) and CLI use the same `OKDiskServiceProtocol` and the same `OperationCoordinator`, all mutating operations are serialized through one queue. No two callers can operate simultaneously regardless of whether they come from GUI or CLI.

- Use a local process lock for `destinations.json` updates.
- Use a lock file at each destination root, for example `.okdisk.lock`, around metadata and payload mutations.
- Acquiring locks for multi-destination writes uses sorted `store_id` order to avoid deadlocks.
- A stale lock can be broken only after proving the owning PID is gone or after an explicit `okdiskctl locks break --confirm` developer command.

### 3.7 Swift package layout

Use SwiftPM with separate app, CLI, and shared core targets.

```text
Package.swift
Sources/
  OKDiskApp/
    main.swift
    EngineHost/          ← starts engine + XPC listener on launch
    UI/                  ← Phase 3: SwiftUI windows
    AppState/
  OKDiskCLI/
    main.swift
    Commands/
  OKDiskCore/
    Models/
    IPC/                 ← XPC protocol definitions (OKDiskServiceProtocol)
    Platform/
    LocalConfig/
    DestinationStore/
    Metadata/
    Storage/
    Sync/
    Restore/
    Verification/
    Reconciliation/
    TestHarness/        ← starts EngineHost + XPC listener for e2e tests
Tests/
  OKDiskCoreTests/
  OKDiskIntegrationTests/
  OKDiskE2ETests/
  OKDiskUITests/         ← Phase 3
scripts/
  build.sh
  run.sh
  test.sh
  test-e2e.sh
Info.plist
Info-Dev.plist
OKDisk.entitlements
README.md
```

Keep domain logic in `OKDiskCore` so it can be tested without launching the UI.

### 3.8 Permissions and macOS access

MVP should not rely on sandboxing.

Recommended behavior:

- App is locally signed/ad-hoc signed for development.
- App runs as the logged-in user.
- (Phase 3) UI uses native folder pickers to capture user intent.
- Source folder identity and configuration are persisted in destination logs.
- Destination folder paths are persisted only in `destinations.json`.
- Onboarding checks whether the engine can read selected source folders and write destination folders.
- If access fails for common protected folders, (Phase 3) UI guides the user to grant Full Disk Access to OKDisk.

Destination validation should check:

- Root directory exists or can be created.
- Root directory is readable and writable.
- Root directory can create/fsync `okdisk.store.json`, `okdisk.metadata.jsonl`, `data/`, and `tmp/`.
- Root has enough free space for the planned writes plus safety margin when the platform reports it.
- If the root appears to be on an external volume and APFS/encryption can be detected, show production safety status; do not block e2e tests on it.

### 3.9 Menu bar UX

Menu bar menu (Phase 1 shows status only; Phase 3 adds full menu):

```text
OKDisk
Status: Idle / Backup running / Restore running / Attention needed
─────────────────────────
(Phase 3)
Backup Now
Restore...
Folders...
Destinations...
Verify Backups
Activity Log...
Preferences...
─────────────────────────
Quit
```

Main management windows (Phase 3):

- Folders: source path, hostname, replica count, last backup, health.
- Destinations: root path, store ID, writable status, online/offline, log status, production safety warning.
- Restore: search/filter files, choose destination, preview overwrite plan.
- Activity: current operation progress and recent operation history.
- Conflict: stale/diverged destination logs, latest candidate, explicit update confirmation.

### 3.10 Build and signing direction

Use script-driven builds:

```text
./scripts/build.sh             # dev app + CLI
./scripts/build.sh --prod      # prod app
./scripts/run.sh               # open dev app
./scripts/test.sh              # unit + integration tests
./scripts/test-e2e.sh          # temp-folder e2e tests
```

Use separate bundle IDs and runtime roots for dev/prod so both can run safely on the same Mac.

---

## 4. Local config

OKDisk has exactly one local durable config file. It stores only the destination directories.

Production config path:

```text
~/Library/Application Support/OKDisk/destinations.json
```

Development config path:

```text
~/Library/Application Support/OKDisk-Dev/destinations.json
```

Test runs can override it:

```text
OKDISK_DESTINATIONS_CONFIG=/tmp/okdisk-e2e/config/destinations.json
```

File format:

```json
{
  "schema_version": 1,
  "destination_roots": [
    "/Volumes/Backup-A/OKDiskStore",
    "/Volumes/Backup-B/OKDiskStore"
  ]
}
```

Rules:

- Store only destination root paths in this file.
- Do not store source folders, replica counts, latest runs, indexes, or operation history in this local config.
- Source folder configuration is stored as `folder.upsert` events in each destination's append-only log.
- Engine working state is rebuilt by replaying connected destination logs into memory.
- Logs and temp files under Application Support are allowed for diagnostics/runtime use, but they are not config or backup truth.
- Tests can override the config path with `OKDISK_DESTINATIONS_CONFIG` or `okdiskctl --config`.
- If the config references a missing path, mark that destination offline and continue with connected paths only.

---

## 5. Folder identity

A source folder is identified by hostname plus full path.

Canonical fields:

```text
hostname     = gethostname(), lowercased, trimmed, stable for display/config
source_path  = absolute standardized POSIX path selected by the user
folder_key   = hostname + "\u{0}" + source_path
folder_id    = sha256("okdisk.folder.v1" + "\u{0}" + folder_key)
```

Rules:

- Do not use destination path, mount path, or volume UUID as part of the folder identity.
- Do not use user-visible folder name alone.
- Do not resolve the selected folder to another host identity.
- Store `hostname`, `source_path`, and `folder_id` in every folder-level metadata record.
- Relative file paths inside the folder use normalized POSIX separators and must never start with `/`.

Future multi-host support can read records for many hostnames while still distinguishing identical paths from different Macs.

---

## 6. Destination identity

Each destination folder has a store identity file at its root.

```text
<destination_root>/okdisk.store.json
```

Example:

```json
{
  "schema_version": 1,
  "store_id": "2D40A7F7-AB7A-4A6D-B56B-2C7F6F51E20B",
  "created_at_utc": "2026-06-24T09:10:00.000Z",
  "created_by_hostname": "aruns-macbook-pro",
  "app": "OKDisk"
}
```

Rules:

- `store_id` is generated once when OKDisk initializes the destination folder.
- `store_id` identifies the replica store even if the folder is on an external disk, a local folder, or a temp e2e folder.
- The local config stores paths; `okdisk.store.json` stores identity.
- If a configured path contains a different `store_id` than the one the user expects, treat it as a new/different destination and warn before using it.

---

## 7. Destination store layout

Every destination root contains:

```text
<destination_root>/
  okdisk.store.json
  okdisk.metadata.jsonl
  .okdisk.lock
  data/
    hosts/
      <hostname>/
        <folder_id>/
          tree/
            <relative source paths mirrored from source>
  tmp/
    <sync_run_id>/
```

Notes:

- `okdisk.metadata.jsonl` is the authoritative append-only metadata/control log for that destination. It records **folder-level config and sync run history only**. Individual files are NOT logged.
- `tree/` is the **authoritative rsync-style mirror** of the source folder. The presence and content of every file is determined by walking `tree/`, not by replaying log events. This keeps the log tiny and makes backup a simple mirror operation.
- Metadata/control events are written to every connected configured destination for each mutation.
- File payloads are stored only on destinations selected by the folder's replica policy.
- A folder's initial replica destinations are selected randomly and stored as `replica_store_ids` in `folder.upsert`, so later backup/restore/verify operations keep using the same destination stores.
- `tmp/` can be removed during startup if no completed run references it.

---

## 8. Metadata JSONL rules

Every line in `okdisk.metadata.jsonl` is a standalone JSON object. After startup replay, the engine maintains an in-memory state model for fast UI/API reads. That model is disposable and can always be rebuilt by replaying connected destination logs.

Common fields:

```json
{
  "schema_version": 1,
  "event_id": "uuid",
  "event_type": "sync_run.start",
  "emitted_at_utc": "2026-06-24T09:10:00.000Z",
  "sync_run_id": "uuid-or-null",
  "sync_run_seq": 42,
  "hostname": "aruns-macbook-pro",
  "source_path": "/Users/arunoda/Documents",
  "folder_id": "sha256-hex"
}
```

Crash safety rules:

- Append one complete JSON object plus newline per event.
- Fsync the metadata file after batches and at run boundaries.
- Ignore partial last lines.
- Ignore JSON lines that fail schema validation.
- Files are mirrored into `tree/` during the run, and `tree/` is the source of truth. A crash mid-run leaves a partially-updated `tree/` that the next run's diff corrects. No run-gating is needed for file content — the rsync-style mirror is self-correcting.
- `sync_run.end` is appended only after all mirror writes/deletes for that run are flushed to the selected replica destinations.
- During compaction, write `okdisk.metadata.compact.tmp`, fsync it, then atomic rename to `okdisk.metadata.jsonl`.

---

## 9. Multi-destination log coordination

The append-only log (`okdisk.metadata.jsonl`) exists independently on every configured destination. This section defines the exact rules for writing, reading, and resolving conflicts across multiple destinations.

### 9.1 Write rules

An event is only considered **successfully written** when it has been appended and fsynced to **every connected configured destination**. There is no partial success.

1. The engine computes `next_sync_run_seq` as `max(completed sync_run_seq across all connected destination logs) + 1`.
2. For each event, the engine appends the same JSON line (same `event_id`, same `sync_run_seq`, same content) to every connected destination's `okdisk.metadata.jsonl`.
3. After appending to each destination, fsync that destination's metadata file.
4. Only after **all** connected destinations have the event appended and fsynced is the write considered successful.
5. If **any** destination fails to append or fsync (disk full, I/O error, disk unmounted), the entire write fails. The engine throws an error and aborts the current operation.
6. Destinations that successfully received the event are not rolled back. The divergence is detected and resolved at the next startup read (see below).
7. The user must fix the failing destination (reconnect the disk, free space, or remove the destination from config) before the next operation can proceed.

### 9.2 Read rules (startup and pre-operation)

On startup, destination attach, and before any mutating operation, the engine reads and validates logs from all connected destinations:

1. Read `okdisk.metadata.jsonl` from every connected destination.
2. For each destination, replay the log line by line:
   - Skip partial last lines (truncated writes from a crash).
   - Skip lines that fail JSON parse or schema validation (corruption).
   - Record the count of skipped lines per destination as a corruption report.
3. For each destination, build a per-destination state model: folder configs, completed sync runs, latest `sync_run_seq`, and reconcile markers.
4. Compare all per-destination state models to determine agreement or conflict (see conflict detection below).
5. If all destinations agree, publish the merged in-memory state and proceed normally.
6. If any destination disagrees or is corrupted, block all mutating operations and present the conflict resolution UI (see conflict resolution below).

### 9.3 Conflict detection

Two destinations **agree** when all of the following match:

- Same set of `folder_id` values with identical latest `folder.upsert` or `folder.remove` records.
- Same latest completed `sync_run_seq` and `sync_run_id`.
- Same set of `state.reconcile` records (by `event_id`).

A destination is classified into one of these states:

| State | Meaning |
|-------|---------|
| **healthy** | Log replays cleanly and agrees with the majority. |
| **stale** | Log replays cleanly but is behind the latest `sync_run_seq` (missing recent events). |
| **diverged** | Log replays cleanly but has events not present in the majority (e.g., a write succeeded on this destination but failed on others, or a different folder config). |
| **corrupted** | Log has unparseable lines beyond the expected partial-last-line tolerance, or the file is missing/unreadable. |
| **offline** | Destination is not connected (disk unmounted, path missing). Excluded from comparison. |

### 9.4 Conflict resolution

When destinations are not all healthy, the engine blocks mutating operations and presents the user with a diagnostic report and a set of **proposed repair actions**. No repair is performed without explicit user confirmation.

The engine selects a **reference destination** — the healthy destination with the highest `sync_run_seq`. If multiple destinations tie, the one with the most recent `sync_run.end` `emitted_at_utc` wins. If no healthy destination exists, the engine reports unrecoverable and requires manual intervention.

For each non-healthy destination, the engine proposes one of these actions:

**Stale destination — copy log:**
- Copy the reference destination's `okdisk.metadata.jsonl` to the stale destination, replacing its log.
- Re-mirror `tree/` from the reference destination **only for folders where this destination is a selected replica** (per the folder's replica policy). If this destination does not hold payload data for a folder, only the log is copied — no `tree/` mirror is needed.
- Action message: "Destination X is behind by N sync runs. Copy the latest log from destination Y? (File mirror will be updated for folders stored on this destination.)"

**Diverged destination — replace log:**
- Replace the diverged destination's `okdisk.metadata.jsonl` with the reference destination's log.
- Re-mirror `tree/` from the reference destination **only for folders where this destination is a selected replica**.
- Action message: "Destination X has diverged. Replace its log with destination Y's state? (File mirror will be updated for folders stored on this destination.)"

**Corrupted destination — replace log:**
- Replace the corrupted destination's `okdisk.metadata.jsonl` with the reference destination's log.
- Re-mirror `tree/` from the reference destination **only for folders where this destination is a selected replica**.
- Action message: "Destination X's log is corrupted (N unparseable lines). Replace its log with destination Y's state? (File mirror will be updated for folders stored on this destination.)"

**Offline destination:**
- Cannot be repaired while offline. The user must reconnect the disk or remove the destination from config.
- Action message: "Destination X is offline. Reconnect the disk or remove it from configuration."

**No healthy destination:**
- All destinations are corrupted, diverged, or offline.
- The engine cannot select a reference. Report unrecoverable with full diagnostic.
- Action message: "No healthy destination available. Manual recovery required."

### 9.5 Repair execution

After the user confirms a repair action:

1. The engine copies the reference destination's `okdisk.metadata.jsonl` to the target destination (atomic write: temp file + fsync + rename).
2. The engine re-mirrors `tree/` from the reference destination to the target destination **only for folders where the target is a selected replica** (rsync-style: copy changed files, delete extra files). For folders where the target is not a replica, only the log is repaired — no `tree/` data is touched.
3. The engine appends a `state.reconcile` event to **all** connected destinations (including the repaired one) recording the repair: which destination was repaired, what action was taken, and which destination was the reference.
4. The engine re-reads all destination logs to confirm agreement.
5. If all destinations now agree, unblock mutating operations and publish the merged state.

If the repair fails (e.g., the target destination goes offline mid-repair), the engine reports the failure and leaves the destination in its current state for the user to address.

---

## 10. Event types

### 10.1 `folder.upsert`

Records source folder configuration. It is appended to every connected configured destination. A source folder cannot be added until at least one destination is attached.

```json
{
  "schema_version": 1,
  "event_id": "8BBF6D3D-7BEF-4789-A028-4CC4DCA1D774",
  "event_type": "folder.upsert",
  "emitted_at_utc": "2026-06-24T09:10:00.000Z",
  "hostname": "aruns-macbook-pro",
  "source_path": "/Users/arunoda/Documents",
  "folder_id": "sha256-hex",
  "replica_count": 2,
  "replica_store_ids": ["store-a", "store-c"],
  "excluded_patterns": [".DS_Store", ".okdisk/**"]
}
```

### 10.2 `folder.remove`

Tombstones a source folder config without deleting already backed-up payloads. MVP can hide removed folders by default while still allowing restore from their latest completed state.

```json
{
  "schema_version": 1,
  "event_id": "uuid",
  "event_type": "folder.remove",
  "emitted_at_utc": "2026-06-24T09:12:00.000Z",
  "hostname": "aruns-macbook-pro",
  "source_path": "/Users/arunoda/Documents",
  "folder_id": "sha256-hex"
}
```

### 10.3 `sync_run.start`

Begins a manual backup run. It is appended to every connected configured destination before mirror writes begin.

```json
{
  "schema_version": 1,
  "event_id": "uuid",
  "event_type": "sync_run.start",
  "emitted_at_utc": "2026-06-24T09:15:00.000Z",
  "sync_run_id": "03F33B53-4E26-4A25-9A28-C55214B5953F",
  "sync_run_seq": 42,
  "hostname": "aruns-macbook-pro",
  "source_path": "/Users/arunoda/Documents",
  "folder_id": "sha256-hex",
  "trigger": "manual"
}
```

### 10.4 `sync_run.end`

Marks the run complete. The event is appended to every connected configured destination after selected replica stores have durable mirror writes/deletes.

```json
{
  "schema_version": 1,
  "event_id": "uuid",
  "event_type": "sync_run.end",
  "emitted_at_utc": "2026-06-24T09:20:00.000Z",
  "sync_run_id": "03F33B53-4E26-4A25-9A28-C55214B5953F",
  "sync_run_seq": 42,
  "hostname": "aruns-macbook-pro",
  "source_path": "/Users/arunoda/Documents",
  "folder_id": "sha256-hex",
  "summary": {
    "files_mirrored": 148,
    "files_deleted": 3,
    "bytes_mirrored": 5242880,
    "errors": 0
  }
}
```

### 10.5 `state.reconcile`

Records that the user approved updating connected destinations to the latest healthy in-memory state after a mismatch warning. This event is appended to every connected configured destination after missing metadata has been copied and required payload replicas are repaired.

```json
{
  "schema_version": 1,
  "event_id": "uuid",
  "event_type": "state.reconcile",
  "emitted_at_utc": "2026-06-24T09:25:00.000Z",
  "approved_by_user": true,
  "source_latest_sync_run_id": "03F33B53-4E26-4A25-9A28-C55214B5953F",
  "source_latest_sync_run_seq": 42,
  "updated_store_ids": ["2D40A7F7-AB7A-4A6D-B56B-2C7F6F51E20B", "B2E8..."],
  "reason": "connected_logs_mismatched"
}
```

---

## 11. Current-state replay

To build current state from one destination:

1. Read `okdisk.metadata.jsonl` line by line.
2. Ignore partial/corrupt records.
3. Record completed sync runs from `sync_run.end`.
4. Apply latest `folder.upsert` or `folder.remove` per `folder_id`.
5. Keep `state.reconcile` records as audit markers; they do not replace folder records during replay.
6. **Files are NOT reconstructed from the log.** The current file index is built by walking `tree/` directly at restore/verify time. This is the rsync-style mirror principle: `tree/` is the source of truth for all files.

Across connected destinations:

- Logs should converge to the same folder configs, completed runs, and reconcile audit markers.
- The latest healthy folder state is the highest completed `sync_run_seq` that satisfies the folder's replica policy.
- `sync_run_id` must match for destinations claiming the same `sync_run_seq`.
- If one destination is behind or diverged, mark it stale/diverged and block mutating operations.
- The UI/CLI must warn the user and require explicit confirmation before the engine updates all connected destinations to the latest healthy state.
- After confirmed reconciliation, append missing metadata/control records to every connected configured destination and re-mirror missing files to replica stores that hold payload data for the affected folders.

---

## 12. Compaction

Compaction keeps only:

- Latest `folder.upsert` or `folder.remove` per folder.
- Required `sync_run.end` records to validate the current sync run history.
- Recent `state.reconcile` audit records and operation summaries for diagnostics, default last 100 runs.

Files are never part of the log, so compaction does not touch them. The `tree/` mirror is self-maintaining via the rsync-style backup flow.

Compaction is itself a destination-local maintenance operation. After compaction, connected destination replay results must match pre-compaction replay results exactly.

---

## 13. Backup flow

The MVP backup trigger is explicit: the user clicks **Backup Now** or runs `okdiskctl backup`.

### 13.1 Preflight

The engine checks:

- No backup/restore/repair/reconcile job is already running.
- Source folder path is readable.
- Source folder still matches the stored `hostname + source_path` identity.
- Required number of replica destinations are connected, writable, and configured.
- Destination roots have enough free space for estimated writes plus safety margin when available.
- `okdisk.store.json` and `okdisk.metadata.jsonl` are valid on each connected configured destination.
- Connected destination logs agree, or the user has explicitly confirmed updating all connected destinations to the latest healthy state.

If replica count cannot be satisfied, the default behavior is to fail before writing. The UI can offer an explicit degraded backup mode later, but not in MVP. If destination logs are mismatched, backup is blocked until reconciliation is confirmed and completed.

### 13.2 Build source snapshot

Walk the source folder and build an in-memory manifest.

Include:

- Directories.
- Regular files.
- Symlinks.
- macOS bundles/packages as normal directories.

Skip:

- `.okdisk/**` if it appears inside a selected source folder.
- `okdisk.store.json`, `okdisk.metadata.jsonl`, `data/`, and `tmp/` if the user accidentally selects a destination root as a source.
- Temporary partial files created by OKDisk.
- Sockets, devices, FIFOs, and other unsupported node types.

Per item capture:

```text
relative_path
node_kind
size
mtime
file_id/inode where available
posix_mode
symlink_target if symlink
```

For changed regular files, compute SHA-256 while copying rather than during the initial scan.

### 13.3 Reconstruct previous state

For each connected configured destination:

- Replay metadata for the folder to get folder config and completed sync runs.
- Determine latest completed run.
- Build the current file index by **walking `tree/`** directly. The tree is the source of truth.

Across destinations:

- Choose the latest completed run that satisfies the replica count.
- Mark destinations behind that run as stale/diverged.
- If connected destination logs differ, stop and ask the user to confirm updating all connected destinations to the latest healthy state before continuing.
- After confirmed reconciliation, continue the backup from the reconciled in-memory state.

### 13.4 Diff

Compare source snapshot to the previous state (the `tree/` walk).

A file is changed when any fast fingerprint differs:

```text
node_kind
size
mtime
file_id/inode
symlink target
```

For regular files, the copy stage computes SHA-256 and records the final content hash. Deep verification catches the rare case where content changed without fingerprint changes.

A path is deleted when it exists in `tree/` but not in the source snapshot.

The diff produces a single set of changes (add/modify/delete) applied by the rsync-style mirror directly to `tree/`. No log events for files.

### 13.5 Start sync run

Generate:

```text
sync_run_id  = UUID
sync_run_seq = max completed sync_run_seq from connected destination logs + 1
```

Append `sync_run.start` to every connected configured destination and fsync metadata.

### 13.6 Copy changed files

For each changed regular file, directory, and symlink, mirror directly into `tree/` on each selected replica destination:

- Use an rsync-style update: compare source vs existing `tree/` entry by size/mtime/inode. If unchanged, skip. If changed or new, copy.
- Write into `tmp/<sync_run_id>/...` first, fsync, then atomically rename to final path under `tree/`.
- Preserve macOS metadata using `copyfile(3)` with data, xattrs, ACLs, and resource forks where available.
- Fsync the temp file and parent directory after rename.
- **No metadata log event is appended for any file.** The `tree/` mirror is the source of truth.

Regular file:

```text
source file -> tmp file -> data/.../tree/<relative_path>
```

Directory:

```text
create directory on selected replica destinations, apply mode/timestamps where practical
```

Symlink:

```text
create symlink with same target on selected replica destinations
```

### 13.7 Apply deletes

For each deleted path on each selected replica destination:

- Remove the `tree/` entry directly.
- Remove empty parent directories where safe.
- No metadata log event is appended.

### 13.8 End sync run

After all mirror writes and deletes are durable on all target replica destinations:

- Append `sync_run.end` to every connected configured destination.
- Fsync metadata on every connected configured destination.
- Update the engine's in-memory state from the appended records.
- Report success to UI/CLI.

The metadata/control log is written to every connected configured destination. It records folder config and sync run history only. Files live in the `tree/` mirror and are not logged. File payloads are written to the destinations selected by the folder's replica policy; destinations that do not hold payload data still receive the metadata events needed to reconstruct global state.

If the process crashes before `sync_run.end`, `tree/` changes from the interrupted run persist and are corrected by the next run's diff — this is the rsync-style mirror guarantee. Leftover tmp files are cleaned by verification/startup cleanup.

---

## 14. Attach destination flow

A destination is any folder the user or CLI chooses as a backup store root.

1. User selects a folder in the GUI or runs `okdiskctl destinations attach <path>`.
2. Engine/CLI creates the folder if requested and validates read/write/fsync support.
3. If `okdisk.store.json` is missing, create it with a new `store_id`.
4. If `okdisk.metadata.jsonl` is missing, create an empty append-only log.
5. Add the root path to `destinations.json` if it is not already present.
6. Replay all connected destination logs.
7. If the new destination is empty and other destinations already have state, require confirmation before copying the latest log state and rsync-mirroring `tree/` from a healthy replica.
8. If the new destination has diverged state, show the normal mismatch reconciliation warning.

Core logic does not require a real external disk. Production UI can still display APFS/encryption warnings when the destination folder appears to be on an external volume.

---

## 15. Restore flow

Restore supports three scopes:

- Full folder restore.
- Subfolder restore.
- Single-file restore.

### 15.1 Select source state

The UI/CLI lets the user choose:

- Hostname.
- Source folder path.
- Restore scope.
- Restore destination path.

MVP restores the latest completed state only. Version selection is out of scope.

### 15.2 Build restore plan

The engine:

- Replays metadata from all connected destinations for folder config and completed sync runs.
- Walks `tree/` on a healthy replica to enumerate all files.
- Picks the latest healthy completed run satisfying available replicas.
- Filters paths by selected scope.
- Chooses a source destination from connected replicas that have the file in `tree/`.
- Verifies that files exist in `tree/` before writing.

If a file exists on multiple replicas, prefer:

1. Destination already verified in current session.
2. Destination with matching size/hash metadata.
3. Destination with lowest current operation load.

### 15.3 Destination safety

Default restore output:

```text
<chosen restore destination>/<original folder name> - OKDisk Restore <timestamp>/
```

Overwrite behavior:

- Never overwrite by default.
- If user chooses overwrite, generate a collision report first.
- For each file write, use temp file in the restore destination directory followed by atomic rename.

Path safety:

- Reject absolute relative paths.
- Reject `..` traversal.
- Normalize Unicode/path separators consistently.
- Do not restore outside the chosen destination.

### 15.4 Restore files

For each path:

- Directory: create directory and apply mode/timestamps after children where practical.
- Regular file: copy from `tree/<relative_path>` to restore temp file. The content in `tree/` is the actual file content.
- Symlink: recreate symlink target.

For regular files:

- Verify size.
- Recompute SHA-256 and compare when deep verify is requested.
- Preserve xattrs/resource forks when available.

### 15.5 Complete restore

On completion:

- Show restored item count, bytes, skipped files, and errors.
- Update only in-memory operation history shown by the UI/CLI.
- Do not write restore summaries to local config.
- Do not write restore events into destination metadata unless a future audit log is required.

---

## 16. Verification flow

### 16.1 Quick verification

Runs after backup and on demand.

Checks:

- `okdisk.metadata.jsonl` parses on every connected destination.
- Latest completed run exists.
- `tree/` is walkable and files are readable.
- Replica count is satisfied for each folder.
- Connected destination logs agree, or conflict details are reported.

### 16.2 Deep verification

Manual or scheduled weekly.

Checks:

- Everything from quick verification.
- `tree/` content matches source by re-running the diff (size/mtime/hash) against the source folder, or against another healthy replica's `tree/`.
- No stale files for deleted paths in `tree/`.

Repair behavior for MVP:

- If one replica is corrupt/missing and another healthy replica exists, offer **Repair Destination** (re-mirror from healthy replica).
- If no healthy replica exists, report the file as unrecoverable.
- Never silently delete questionable data unless it is clearly under `tmp/` or unreferenced by any completed run.

---

## 17. Failure handling

Destination unavailable mid-backup:

- Cancel current run.
- Do not append `sync_run.end` to remaining destinations if possible.
- Mark destination offline/unavailable in memory.
- `tree/` mirror changes on the unavailable destination may be partial; the next successful run re-mirrors from the diff.

Source file changes while copying:

- Detect if size/mtime changed after copy.
- Retry once by default.
- If still changing, skip file and fail the run unless user later enables best-effort mode.

Permission denied:

- Fail the current folder backup.
- Surface exact path and missing permission guidance.

Out of space:

- Fail run before `sync_run.end`.
- Leave existing completed backup state intact.
- Cleanup temp files where safe.

Log mismatch:

- Block backup/restore/repair mutations.
- Show stale/diverged destinations and candidate latest state.
- Require explicit confirmation before writing reconcile records or copying missing payloads.

---

## 18. Reliability principles

- The app is the single engine owner. Both GUI and CLI use `OKDiskServiceProtocol` — the GUI calls it in-process, the CLI via XPC. The `OperationCoordinator` serializes all operations regardless of caller.
- The engine writes metadata/control events to every connected configured destination.
- File payloads are written only to destinations selected by the folder replica policy.
- The engine keeps in-memory working state; durable backup state lives in destination JSONL logs and `tree/` mirrors.
- The only local durable config is the destination directory list.
- If connected destination logs differ, OKDisk warns the user and requires confirmation before updating all destinations to the latest healthy state.
- All files use an rsync-style mirror into `tree/`. The `tree/` directory is the source of truth for file content; the metadata log does not track individual files.
- A crash mid-run leaves a partially-updated `tree/` that the next run's diff corrects. No run-gating is needed for file content — the rsync-style mirror is self-correcting.
- File writes use temp files followed by atomic rename.
- Metadata append and compaction are fsync-aware.
- Restore defaults to a new destination folder and never overwrites user data without explicit confirmation.
- Every persisted timestamp is an ISO-8601 UTC string.
- Every file path stored in metadata is relative to the configured source folder, never an absolute restore path.

---

## 19. Product behavior target

1. User opens OKDisk from the menu bar.
2. User attaches one or more destination folders. In production these will normally live on external encrypted SSDs; in tests they are temporary directories.
3. OKDisk writes the destination paths to the single local config file.
4. User adds a source folder using a native folder picker.
5. OKDisk appends the folder config to `okdisk.metadata.jsonl` at the root of every connected destination.
6. User clicks **Backup Now**.
7. The engine scans the folder, mirrors all changed files into `tree/` using an rsync-style update on each replica destination, and appends a completed sync run to every connected destination log.
8. User can restore the whole folder, a subfolder, or a single file from any available healthy replica.
9. Verification can confirm that metadata, `tree/` content, hashes, and replica counts still match.

---

## 20. MVP acceptance criteria

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

---

## Implementation and testing documents

The design spec above defines *what* to build. The following documents define *how* to build and test it:

- [Implementation Plan](./implementation-plan.md) — phased working order and acceptance criteria.
- [Core + Engine Plan](./implementation-plan-core-service.md) — core engine, app host, XPC, storage, restore, verification.
- [CLI Plan](./implementation-plan-cli.md) — `okdiskctl` commands and test harness support.
- [GUI Plan](./implementation-plan-gui.md) — menu bar app and management windows.
- [Testing Strategy](./testing-strategy.md) — unit, integration, e2e, crash/corruption, and UI tests.
