# Storage and Metadata

## Local destination config

The only local durable config is the destination directory list:

```text
~/Library/Application Support/OKDisk/destinations.json
```

Format:

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
- Do not store source folder configs, file indexes, latest sync state, replica choices, or operation history locally.
- Tests can override the config path with `OKDISK_DESTINATIONS_CONFIG` or `okdiskctl --config`.
- If the config references a missing path, mark that destination offline and continue with connected paths only.

## Folder identity

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

## Destination identity

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

## Destination store layout

Every destination root contains the append-only file at the root:

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
- `tmp/` can be removed during startup if no completed run references it.

## Metadata JSONL rules

Every line in `okdisk.metadata.jsonl` is a standalone JSON object. After startup replay, the service maintains an in-memory state model for fast UI/API reads. That model is disposable and can always be rebuilt by replaying connected destination logs.

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

## Multi-destination log coordination

The append-only log (`okdisk.metadata.jsonl`) exists independently on every configured destination. This section defines the exact rules for writing, reading, and resolving conflicts across multiple destinations.

### Write rules

An event is only considered **successfully written** when it has been appended and fsynced to **every connected configured destination**. There is no partial success.

1. The engine computes `next_sync_run_seq` as `max(completed sync_run_seq across all connected destination logs) + 1`.
2. For each event, the engine appends the same JSON line (same `event_id`, same `sync_run_seq`, same content) to every connected destination's `okdisk.metadata.jsonl`.
3. After appending to each destination, fsync that destination's metadata file.
4. Only after **all** connected destinations have the event appended and fsynced is the write considered successful.
5. If **any** destination fails to append or fsync (disk full, I/O error, disk unmounted), the entire write fails. The engine throws an error and aborts the current operation.
6. Destinations that successfully received the event are not rolled back. The divergence is detected and resolved at the next startup read (see below).
7. The user must fix the failing destination (reconnect the disk, free space, or remove the destination from config) before the next operation can proceed.

### Read rules (startup and pre-operation)

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

### Conflict detection

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

### Conflict resolution

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

### Repair execution

After the user confirms a repair action:

1. The engine copies the reference destination's `okdisk.metadata.jsonl` to the target destination (atomic write: temp file + fsync + rename).
2. The engine re-mirrors `tree/` from the reference destination to the target destination **only for folders where the target is a selected replica** (rsync-style: copy changed files, delete extra files). For folders where the target is not a replica, only the log is repaired — no `tree/` data is touched.
3. The engine appends a `state.reconcile` event to **all** connected destinations (including the repaired one) recording the repair: which destination was repaired, what action was taken, and which destination was the reference.
4. The engine re-reads all destination logs to confirm agreement.
5. If all destinations now agree, unblock mutating operations and publish the merged state.

If the repair fails (e.g., the target destination goes offline mid-repair), the engine reports the failure and leaves the destination in its current state for the user to address.

## Event types

### `folder.upsert`

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
  "excluded_patterns": [".DS_Store", ".okdisk/**"]
}
```

### `folder.remove`

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

### `sync_run.start`

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

### `sync_run.end`

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

### `state.reconcile`

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

## Current-state replay

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
- The UI/CLI must warn the user and require explicit confirmation before the service updates all connected destinations to the latest healthy state.
- After confirmed reconciliation, append missing metadata/control records to every connected configured destination and re-mirror missing files to replica stores that hold payload data for the affected folders.

## Compaction

Compaction keeps only:

- Latest `folder.upsert` or `folder.remove` per folder.
- Required `sync_run.end` records to validate the current sync run history.
- Recent `state.reconcile` audit records and operation summaries for diagnostics, default last 100 runs.

Files are never part of the log, so compaction does not touch them. The `tree/` mirror is self-maintaining via the rsync-style backup flow.

Compaction is itself a destination-local maintenance operation. After compaction, connected destination replay results must match pre-compaction replay results exactly.
