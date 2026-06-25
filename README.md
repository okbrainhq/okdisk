# OKDisk

OKDisk is a SwiftPM prototype for reliable folder backup/restore to ordinary destination folders on macOS.

## What is implemented

- `OKDiskCore` — local destination config, destination store initialization, JSONL metadata replay, rsync-style `tree/` mirroring, restore, deep verification, repair, and confirmed reconciliation.
- `OKDiskService` / `OperationCoordinator` — one protocol-shaped async service surface that serializes mutating jobs for menu bar/CLI callers.
- `OKDiskApp` — native SwiftUI menu bar app that starts the engine, exposes the XPC status endpoint (`com.okdisk.service.xpc`), shows a compact status menu, and provides dashboard tabs for status, destinations, folders, backup, restore, verification, conflicts, and recent activity.
- `OKDiskCoreTests` / `OKDiskE2ETests` — temp-folder tests covering backup, incremental mirror behavior, restore scopes, verification, fault recovery, repair, reconciliation, and config isolation.

No CLI is included yet.

## Scripts

```bash
./scripts/build.sh          # builds OKDisk-Dev.app
./scripts/build.sh --prod   # builds OKDisk.app
./scripts/run.sh            # opens the dev menu bar app
./scripts/test.sh           # runs tests and builds the dev app
./scripts/test-e2e.sh       # runs just the E2E suite
```

## Programmatic smoke flow

```swift
let service = OKDiskService(configPath: "/tmp/okdisk/config/destinations.json", environment: .test)
try await service.attachDestination(.init(rootPath: "/tmp/okdisk/dest-a"))
try await service.attachDestination(.init(rootPath: "/tmp/okdisk/dest-b"))
let folder = try await service.addFolder(.init(sourcePath: "/tmp/okdisk/src/Documents", replicaCount: 2))
let backupID = try await service.startBackup(folderID: folder.folderID)
let verifyID = try await service.startVerification(.init(deep: true))
```

Destination config stores only `destination_roots`; source-folder configuration and sync history live in each destination's `okdisk.metadata.jsonl`, while payloads are mirrored directly under `data/hosts/<hostname>/<folder_id>/tree/`.
