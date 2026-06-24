# Architecture

## High-level shape

OKDisk has two macOS executables/entry points:

1. `OKDisk.app` — menu bar app that hosts the `OKDiskCore` engine in-process and exposes an XPC listener. Both the GUI and the CLI are clients of the same `OKDiskServiceProtocol`. In the initial version the app is headless (no GUI windows); the SwiftUI UI is added in a later phase.
2. `okdiskctl` — CLI that connects to the running app over XPC and calls `OKDiskServiceProtocol`.

There is no separate launchd service. The app process IS the service. When the app launches, it starts the engine and the XPC listener. When the app quits, the engine stops.

### Phased delivery

| Phase | What ships | Purpose |
|-------|-----------|---------|
| **Phase 1: Headless app + core** | `OKDisk.app` (menu bar icon only, no windows) + `OKDiskCore` engine + XPC listener | Core reliability — backup, restore, verify, crash safety. E2e tests drive the engine via XPC through a test harness. |
| **Phase 2: CLI** | `okdiskctl` | Operator/test driver. Connects to running app (or test harness) via XPC. Full MVP without GUI. |
| **Phase 3: GUI** | SwiftUI windows inside `OKDisk.app` | Management UI — destinations, folders, backup now, restore, verify, conflicts. |

Both the GUI and the CLI use the same `OKDiskServiceProtocol` interface. The GUI calls the protocol implementation directly (same process, same object — no IPC overhead). The CLI calls the same protocol via XPC. The `OperationCoordinator` actor serializes all operations regardless of caller, so there is no risk of the GUI and CLI stepping on each other.

## Destination-folder abstraction

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

## Why the app hosts the engine (no launchd)

For the MVP, the menu bar app process hosts the core engine directly. There is no separate launchd LaunchAgent.

Reasons:

- The app backs up the current user's files and needs the same access the user has.
- A menu bar app stays running in the background, so the engine is available whenever the app is open.
- One process, one binary — no launchd plist, no service lifecycle management, no service startup race conditions.
- Simpler testing — e2e tests start a test harness process that runs the same `EngineHost` (engine + XPC listener) with a test config; the CLI connects to it via XPC. No full app launch needed.
- If automatic scheduled backups are needed later, a lightweight launchd helper can be added without reworking the core.

## Local config

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

- Do not store source folders, replica counts, latest runs, indexes, or operation history in this local config.
- Source folder configuration is stored as `folder.upsert` events in each destination's append-only log.
- Service working state is rebuilt by replaying connected destination logs into memory.
- Logs and temp files under Application Support are allowed for diagnostics/runtime use, but they are not config or backup truth.

## Process responsibilities

### OKDisk menu bar app

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

### Engine (inside OKDisk.app)

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

### okdiskctl CLI (Phase 2)

Responsibilities:

- Attach/list/remove destination folders in the local config file.
- Add/list/update source folders through the engine via XPC (`OKDiskServiceProtocol`).
- Run backup, restore, verify, reconcile, and compact.
- Print machine-readable JSON for e2e assertions.
- Support `--config <path>` so tests can run without touching the user's real config.
- The CLI is always an XPC client — it connects to the running app (or a test harness for e2e tests). There is no in-process mode.

## IPC

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

## Locking and write ownership

Because both the app (via GUI) and CLI use the same `OKDiskServiceProtocol` and the same `OperationCoordinator`, all mutating operations are serialized through one queue. No two callers can operate simultaneously regardless of whether they come from GUI or CLI.

- Use a local process lock for `destinations.json` updates.
- Use a lock file at each destination root, for example `.okdisk.lock`, around metadata and payload mutations.
- Acquiring locks for multi-destination writes uses sorted `store_id` order to avoid deadlocks.
- A stale lock can be broken only after proving the owning PID is gone or after an explicit `okdiskctl locks break --confirm` developer command.

## Swift package layout

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

## Permissions and macOS access

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

## Menu bar UX

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

## Build and signing direction

Use script-driven builds:

```text
./scripts/build.sh             # dev app + CLI
./scripts/build.sh --prod      # prod app
./scripts/run.sh               # open dev app
./scripts/test.sh              # unit + integration tests
./scripts/test-e2e.sh          # temp-folder e2e tests
```

Use separate bundle IDs and runtime roots for dev/prod so both can run safely on the same Mac.
