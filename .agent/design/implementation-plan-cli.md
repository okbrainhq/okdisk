# CLI Implementation Plan

> **Phase 2 deliverable.** The CLI ships after the headless app + core engine (Phase 1) is proven. It is always an XPC client — it connects to the running app (or a test harness for e2e tests) via `OKDiskServiceProtocol`.

`okdiskctl` is both a developer/operator tool and the primary e2e test driver. It calls `OKDiskServiceProtocol` over XPC — the same interface the GUI uses.

## Part 1: CLI scaffold

Deliverables:

- `OKDiskCLI` SwiftPM executable target.
- Argument parser setup.
- Global options:
  - `--config <path>`
  - `--json`
- Consistent exit codes.
- Structured error output.

Acceptance:

- `okdiskctl --help` lists command groups.
- `--config` isolates all local config reads/writes.
- `--json` output is machine-readable for tests.
- CLI always connects via XPC to the running app or test harness.

## Part 2: Destination commands

Commands:

```text
okdiskctl destinations list
okdiskctl destinations attach <path>
okdiskctl destinations remove <path>
okdiskctl destinations inspect <path>
```

Deliverables:

- Attach initializes `okdisk.store.json`, `okdisk.metadata.jsonl`, `data/`, and `tmp/`.
- Attach writes the root path to `destinations.json`.
- List reports path, store ID, online/offline, writable, log status, and conflict status.
- Inspect prints store and replay details for debugging.

Acceptance:

- Two temp folders can be attached and listed.
- Removing a destination only removes the path from local config; it does not delete backup data.
- Missing destination paths are reported clearly.

## Part 3: Folder commands

Commands:

```text
okdiskctl folders list
okdiskctl folders add <source-path> --replicas <n>
okdiskctl folders update <folder-id> [--replicas <n>]
okdiskctl folders remove <folder-id>
```

Deliverables:

- Add computes `folder_id` from hostname + full source path.
- Add/update/remove appends metadata events to every connected destination.
- List is rebuilt from destination logs.

Acceptance:

- Folder config survives CLI process restart.
- Same path on same host is handled predictably.
- Folder config is not written to local config.

## Part 4: Backup commands

Commands:

```text
okdiskctl backup --all
okdiskctl backup --folder <folder-id>
```

Deliverables:

- Runs the manual backup flow (rsync-style mirror into `tree/`).
- Prints operation summary (files mirrored, files deleted, bytes, errors).
- Supports progress output for humans and final JSON for tests.
- Supports fault injection in test builds:
  - `--fail-after sync-start`
  - `--fail-after payload-write:<n>`
  - `--fail-before sync-end`

Acceptance:

- CLI can back up source fixtures to two destination folders.
- E2E tests can assert JSON summary.
- Fault injection proves incomplete runs are self-correcting.

## Part 5: Restore commands

Commands:

```text
okdiskctl restore --folder <folder-id> --to <path>
okdiskctl restore --folder <folder-id> --subpath <relative-path> --to <path>
okdiskctl restore --folder <folder-id> --file <relative-path> --to <path>
okdiskctl restore --folder <folder-id> --to <path> --overwrite-confirmed
```

Deliverables:

- Builds restore plan from latest completed state (walks `tree/` on a healthy replica).
- Supports full folder, subfolder, and single-file restore.
- Emits collision report before overwrite.
- Emits restored file list in JSON mode.

Acceptance:

- Restored output matches source fixture content.
- Files restore from `tree/` content directly.
- Path traversal restore requests are rejected.

## Part 6: Verify, repair, and reconcile commands

Commands:

```text
okdiskctl verify --quick
okdiskctl verify --deep
okdiskctl repair --folder <folder-id> --confirm
okdiskctl conflicts list
okdiskctl reconcile --confirm
okdiskctl compact --confirm
```

Deliverables:

- Verification reports missing/corrupt replicas (`tree/` entries).
- Repair re-mirrors from healthy replicas.
- Conflicts list stale/diverged destinations.
- Reconcile requires `--confirm`.
- Compact requires `--confirm`.

Acceptance:

- Mismatched logs block backup until `reconcile --confirm`.
- Repair succeeds when at least one healthy replica exists.
- Commands refuse destructive/repair actions without confirmation.

## Part 7: E2E script integration

Deliverables:

- `scripts/test-e2e.sh`.
- Helper to create temp roots and deterministic fixtures.
- Recursive content-hash comparison helper.
- Failed test fixture preservation.
- Parallel-safe config paths.

Acceptance:

- E2e tests run with no external disks.
- E2e tests do not modify real `~/Library/Application Support/OKDisk`.
- E2e tests start a test harness process (same `EngineHost` code as the app) with a test config, then connect the CLI via XPC.
- Failure output includes temp root and last command JSON.

## CLI done criteria

- CLI can perform the complete MVP without GUI.
- CLI connects to the running app (or test harness) via XPC — no in-process mode.
- CLI JSON output is stable enough for tests.
- All major logic paths are covered by CLI e2e tests.
