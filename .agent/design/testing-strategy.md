# Testing Strategy

OKDisk is backup software, so correctness is more important than UI polish. The test strategy is logic-heavy and uses ordinary folders as backup destinations so e2e tests do not depend on external disks.

## Test pyramid

1. Unit tests for pure logic and metadata rules.
2. Integration tests for filesystem operations against temporary folders.
3. CLI-driven e2e tests for real backup/restore/verify flows.
4. A small number of UI interaction tests for critical menu/window paths.
5. Manual production-safety checks for macOS permissions and real encrypted SSD behavior.

## Test harness principles

- Every automated test uses a temporary test root.
- Destination folders are normal directories under the test root.
- Tests override local config with `OKDISK_DESTINATIONS_CONFIG` or `okdiskctl --config`.
- Source folders are generated fixtures under the test root.
- Tests assert restored file content, metadata replay state, replica placement, and log behavior.
- Tests never touch the user's real OKDisk config or real backup destinations.

Example e2e layout:

```text
/tmp/okdisk-e2e/<test-id>/
  config/
    destinations.json
  src/
    Documents/
  destinations/
    dest-a/
      okdisk.store.json
      okdisk.metadata.jsonl
      data/
      tmp/
    dest-b/
      okdisk.store.json
      okdisk.metadata.jsonl
      data/
      tmp/
  restore/
```

## Unit tests

Target: `OKDiskCoreTests`.

Required coverage:

- Folder ID generation from `hostname + source_path`.
- Path normalization and traversal rejection.
- Destination config read/write with atomic replacement.
- Destination store initialization and identity validation.
- JSONL append encoding.
- JSONL replay with partial/corrupt last line ignored.
- Current-state reconstruction (folder configs, sync runs).
- Tree walker that enumerates `tree/` to build the file index.
- Metadata compaction preserving replay result.
- Diff algorithm for add/modify/delete/no-op (source vs `tree/`).
- Replica selection by `replica_count`.
- Reconcile candidate selection when one destination is behind.
- Reconcile refusal when two destinations contain incompatible latest states.

## Integration tests

Target: `OKDiskIntegrationTests`.

Use Swift `FileManager` temporary directories and the real filesystem implementation.

Required scenarios:

- Initialize one destination folder.
- Initialize two destination folders and verify each has a root append-only log.
- Attach a new empty destination after existing backups and reconcile it.
- Add folder config and replay it from destination logs after process restart.
- First backup with regular files, nested directories, symlinks, and xattrs where supported. Verify `tree/` content matches source.
- Incremental backup with adds, modifies, deletes, and renames. Changes appear in `tree/` without log events.
- Incomplete run: write `sync_run.start` but no `sync_run.end`; `tree/` changes persist and are corrected by the next run.
- Corrupt/partial metadata line at end of log; replay must ignore it.
- Destination unavailable during backup; run must fail without corrupting latest completed state.
- Verification detects missing `tree/` entry, hash mismatch, and stale deleted file.
- Repair re-mirrors from healthy replica; appends reconciliation/repair metadata where needed.
- Restore collision report prevents overwrite unless explicitly allowed.
- Restore path traversal attempts are rejected.

## CLI-driven e2e tests

Target: `OKDiskE2ETests` plus `scripts/test-e2e.sh`.

The CLI is the main e2e driver because it exercises the same `OKDiskServiceProtocol` that the GUI uses. E2e tests start a test harness process (same `EngineHost` code as the app) with a test config, then connect the CLI via XPC.

Baseline command shape:

```text
okdiskctl --config /tmp/okdisk-e2e/config/destinations.json --json destinations attach /tmp/okdisk-e2e/destinations/dest-a
okdiskctl --config /tmp/okdisk-e2e/config/destinations.json --json destinations attach /tmp/okdisk-e2e/destinations/dest-b
okdiskctl --config /tmp/okdisk-e2e/config/destinations.json --json folders add /tmp/okdisk-e2e/src/Documents --replicas 2
okdiskctl --config /tmp/okdisk-e2e/config/destinations.json --json backup --all
okdiskctl --config /tmp/okdisk-e2e/config/destinations.json --json restore --folder <folder_id> --to /tmp/okdisk-e2e/restore
okdiskctl --config /tmp/okdisk-e2e/config/destinations.json --json verify --deep
```

E2E scenario groups:

### Backup/restore correctness

- First backup to two destination folders.
- Restore full folder and compare recursive content hash with source.
- Restore one subfolder and compare only selected subtree.
- Restore one file by exact relative path.
- Add/modify/delete files, run backup again, restore, and compare to updated source.

### Mirror behavior

- Create files of various sizes, nested directories, and symlinks.
- Run backup.
- Verify all files appear in `tree/` with actual content.
- Verify no `file.upsert` or `file.delete` events exist in `okdisk.metadata.jsonl`.
- Verify `sync_run.start` and `sync_run.end` are the only sync-related events.
- Modify and delete files, run backup again, verify `tree/` reflects changes.

### Crash safety

Use fault injection flags in core/CLI test mode:

```text
--fail-after sync-start
--fail-after payload-write:2
--fail-before sync-end
```

Assertions:

- `tree/` may have partial changes from the interrupted run.
- The next successful run corrects them via diff.
- Temporary files are cleaned by startup/verification cleanup.
- Next successful backup can proceed.

### Mismatch/reconciliation

- Back up with two destinations.
- Remove one destination from config temporarily and run another backup with remaining destination if policy allows in a controlled test mode, or manually truncate one log.
- Reattach stale destination.
- Verify `backup` is blocked with a structured conflict response.
- Run `reconcile --confirm`.
- Verify logs converge and backup can continue.

### Corruption/repair

- Delete one replica's `tree/` entry.
- Run quick verify; expect missing file report.
- Run repair; expect file re-mirrored from healthy replica.
- Delete all replicas for one file.
- Run verify; expect unrecoverable report and no silent deletion.

### Config isolation

- Run two e2e test roots in parallel with different `--config` paths.
- Verify they do not see each other's destinations, folders, logs, or restored output.

## UI interaction tests

Target: `OKDiskUITests` using XCTest UI automation.

Keep UI tests few and stable. They should verify critical user paths, not every visual state.

Initial UI tests:

1. Launch dev app with a temporary config path.
2. Open the menu bar extra and verify status is visible.
3. Open Destinations window, attach a test destination folder, and verify it appears.
4. Open Folders window, add a test source folder, and verify `hostname + source path` appears.
5. Click **Backup Now**, poll until success, and verify operation summary appears.
6. Open Restore window, select a file, choose restore destination, run restore, and verify output exists.
7. Create a destination log mismatch fixture, launch app, and verify the conflict warning appears before reconcile.

UI test design notes:

- Use app launch arguments/environment to point at temporary config and test roots.
- Prefer stable accessibility identifiers over text matching.
- Stub or run `OKDiskServiceProtocol` in dev/test mode via the test harness so tests do not require launching the full app.
- Do not test APFS/encryption UI in automation; keep it manual.

## Manual macOS tests

Manual tests are still needed for platform integration:

- Documents/Desktop protected folder access.
- Full Disk Access onboarding for app.
- Destination folder on APFS-encrypted external SSD.
- Destination folder on an unencrypted disk shows a warning but can be used if user accepts.
- External disk unmount/remount while idle.
- External disk disconnect mid-backup.
- App restart rebuilds state from destination logs.
- App update preserving `destinations.json` and destination logs.

## Test scripts

Required scripts:

```text
./scripts/test.sh              # unit + integration
./scripts/test-e2e.sh          # CLI e2e temp-folder suite
./scripts/test-ui.sh           # minimal UI interaction suite
./scripts/clean-test-data.sh   # remove stale temp roots if needed
```

`./scripts/test-e2e.sh` should fail fast, print the temp root on failure, and preserve failed fixtures for debugging.

## Acceptance gate

Before MVP is considered reliable:

- Unit and integration tests pass locally.
- CLI e2e tests pass using temp destination folders.
- Crash/fault injection cases pass.
- Mismatch/reconciliation e2e tests pass.
- At least the minimal UI interaction tests pass on the dev app.
- One manual smoke test succeeds with two real destination folders on external SSDs.
