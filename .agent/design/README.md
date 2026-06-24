# OKDisk MVP Reference Implementation Design

This directory defines the MVP reference design for OKDisk: a native macOS, application-level backup system for personal folders. The production target is APFS-encrypted external SSDs, but the MVP core treats every backup target as a normal destination folder so the same logic is easy to test end-to-end.

## MVP scope

In scope:

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

Out of scope for MVP:

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

## Phased delivery

| Phase | What ships | Purpose |
|-------|-----------|---------|
| **Phase 1** | `OKDisk.app` (menu bar icon only) + `OKDiskCore` engine + XPC listener | Core reliability — backup, restore, verify, crash safety. E2e tests via XPC through a test harness. |
| **Phase 2** | `okdiskctl` CLI | Operator/test driver. Full MVP without GUI. |
| **Phase 3** | SwiftUI windows inside `OKDisk.app` | Management UI — destinations, folders, backup, restore, verify, conflicts. |

## Design documents

- [Architecture](./architecture.md) — app/CLI design, IPC, local destination config, package layout, phased delivery.
- [Storage and Metadata](./storage-metadata.md) — destination layout, folder IDs, JSONL schemas, replay rules.
- [Backup and Restore Flows](./backup-restore-flows.md) — algorithms, crash safety, verification, restore behavior.
- [Testing Strategy](./testing-strategy.md) — unit, integration, e2e, crash/corruption, and UI interaction tests.
- [Implementation Plan](./implementation-plan.md) — plan index and phased working order.
- [Core + Engine Plan](./implementation-plan-core-service.md) — core engine, app host, XPC, storage, restore, verification.
- [CLI Plan](./implementation-plan-cli.md) — `okdiskctl` commands and test harness support.
- [GUI Plan](./implementation-plan-gui.md) — menu bar app and minimal UI automation.

## Product behavior target

1. User opens OKDisk from the menu bar.
2. User attaches one or more destination folders. In production these will normally live on external encrypted SSDs; in tests they are temporary directories.
3. OKDisk writes the destination paths to the single local config file.
4. User adds a source folder using a native folder picker.
5. OKDisk appends the folder config to `okdisk.metadata.jsonl` at the root of every connected destination.
6. User clicks **Backup Now**.
7. The engine scans the folder, mirrors all changed files into `tree/` using an rsync-style update on each replica destination, and appends a completed sync run to every connected destination log.
8. User can restore the whole folder, a subfolder, or a single file from any available healthy replica.
9. Verification can confirm that metadata, `tree/` content, hashes, and replica counts still match.

## Reliability principles

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
