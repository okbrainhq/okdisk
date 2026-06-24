# Backup and Restore Flows

## Startup state load and log reconciliation

On startup, destination attach, and before any backup/restore/verification mutation, the engine rebuilds state from configured destination folders. The exact rules for reading, writing, and resolving conflicts across multiple destination logs are defined in [Multi-destination log coordination](./storage-metadata.md#multi-destination-log-coordination).

Summary:

1. Read `destinations.json` from the configured local path.
2. For each destination root, read or initialize `okdisk.store.json`.
3. Read and replay each connected destination's `okdisk.metadata.jsonl` (skip partial/corrupt lines, record corruption report).
4. Build per-destination state models: folder configs, completed sync runs, latest `sync_run_seq`, reconcile markers.
5. Compare all per-destination state models to classify each as healthy, stale, diverged, corrupted, or offline.
6. If all destinations are healthy and agree, publish the merged in-memory state and proceed.
7. If any destination is not healthy, block mutating operations and present the conflict resolution UI with proposed repair actions. No repair is performed without explicit user confirmation.

The in-memory state is a working cache only. It is always rebuildable from destination logs and is never treated as durable truth.

## Attach destination flow

A destination is any folder the user or CLI chooses as a backup store root.

1. User selects a folder in the GUI or runs `okdiskctl destinations attach <path>`.
2. Service/CLI creates the folder if requested and validates read/write/fsync support.
3. If `okdisk.store.json` is missing, create it with a new `store_id`.
4. If `okdisk.metadata.jsonl` is missing, create an empty append-only log.
5. Add the root path to `destinations.json` if it is not already present.
6. Replay all connected destination logs.
7. If the new destination is empty and other destinations already have state, require confirmation before copying the latest log state and rsync-mirroring `tree/` from a healthy replica.
8. If the new destination has diverged state, show the normal mismatch reconciliation warning.

Core logic does not require a real external disk. Production UI can still display APFS/encryption warnings when the destination folder appears to be on an external volume.

## Manual backup flow

The MVP backup trigger is explicit: the user clicks **Backup Now** or runs `okdiskctl backup`.

### 1. Preflight

The service checks:

- No backup/restore/repair/reconcile job is already running.
- Source folder path is readable.
- Source folder still matches the stored `hostname + source_path` identity.
- Required number of replica destinations are connected, writable, and configured.
- Destination roots have enough free space for estimated writes plus safety margin when available.
- `okdisk.store.json` and `okdisk.metadata.jsonl` are valid on each connected configured destination.
- Connected destination logs agree, or the user has explicitly confirmed updating all connected destinations to the latest healthy state.

If replica count cannot be satisfied, the default behavior is to fail before writing. The UI can offer an explicit degraded backup mode later, but not in MVP. If destination logs are mismatched, backup is blocked until reconciliation is confirmed and completed.

### 2. Build source snapshot

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

### 3. Reconstruct previous state

For each connected configured destination:

- Replay metadata for the folder to get folder config and completed sync runs.
- Determine latest completed run.
- Build the current file index by **walking `tree/`** directly. The tree is the source of truth.

Across destinations:

- Choose the latest completed run that satisfies the replica count.
- Mark destinations behind that run as stale/diverged.
- If connected destination logs differ, stop and ask the user to confirm updating all connected destinations to the latest healthy state before continuing.
- After confirmed reconciliation, continue the backup from the reconciled in-memory state.

### 4. Diff

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

### 5. Start sync run

Generate:

```text
sync_run_id  = UUID
sync_run_seq = max completed sync_run_seq from connected destination logs + 1
```

Append `sync_run.start` to every connected configured destination and fsync metadata.

### 6. Copy changed files

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

### 7. Apply deletes

For each deleted path on each selected replica destination:

- Remove the `tree/` entry directly.
- Remove empty parent directories where safe.
- No metadata log event is appended.

### 8. End sync run

After all mirror writes and deletes are durable on all target replica destinations:

- Append `sync_run.end` to every connected configured destination.
- Fsync metadata on every connected configured destination.
- Update the service's in-memory state from the appended records.
- Report success to UI/CLI.

The metadata/control log is written to every connected configured destination. It records folder config and sync run history only. Files live in the `tree/` mirror and are not logged. File payloads are written to the destinations selected by the folder's replica policy; destinations that do not hold payload data still receive the metadata events needed to reconstruct global state.

If the process crashes before `sync_run.end`, `tree/` changes from the interrupted run persist and are corrected by the next run's diff — this is the rsync-style mirror guarantee. Leftover tmp files are cleaned by verification/startup cleanup.

## Restore flow

Restore supports three scopes:

- Full folder restore.
- Subfolder restore.
- Single-file restore.

### 1. Select source state

The UI/CLI lets the user choose:

- Hostname.
- Source folder path.
- Restore scope.
- Restore destination path.

MVP restores the latest completed state only. Version selection is out of scope.

### 2. Build restore plan

The service:

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

### 3. Destination safety

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

### 4. Restore files

For each path:

- Directory: create directory and apply mode/timestamps after children where practical.
- Regular file: copy from `tree/<relative_path>` to restore temp file. The content in `tree/` is the actual file content.
- Symlink: recreate symlink target.

For regular files:

- Verify size.
- Recompute SHA-256 and compare when deep verify is requested.
- Preserve xattrs/resource forks when available.

### 5. Complete restore

On completion:

- Show restored item count, bytes, skipped files, and errors.
- Update only in-memory operation history shown by the UI/CLI.
- Do not write restore summaries to local config.
- Do not write restore events into destination metadata unless a future audit log is required.

## Verification flow

Verification modes:

### Quick verification

Runs after backup and on demand.

Checks:

- `okdisk.metadata.jsonl` parses on every connected destination.
- Latest completed run exists.
- `tree/` is walkable and files are readable.
- Replica count is satisfied for each folder.
- Connected destination logs agree, or conflict details are reported.

### Deep verification

Manual or scheduled weekly.

Checks:

- Everything from quick verification.
- `tree/` content matches source by re-running the diff (size/mtime/hash) against the source folder, or against another healthy replica's `tree/`.
- No stale files for deleted paths in `tree/`.

Repair behavior for MVP:

- If one replica is corrupt/missing and another healthy replica exists, offer **Repair Destination** (re-mirror from healthy replica).
- If no healthy replica exists, report the file as unrecoverable.
- Never silently delete questionable data unless it is clearly under `tmp/` or unreferenced by any completed run.

## Failure handling

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
