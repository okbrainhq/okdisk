# OKDisk

OKDisk is a SwiftPM prototype for reliable folder backup/restore to ordinary destination folders.

## Targets

- `OKDiskCore` — config, destination store, metadata replay, backup, restore, verify, repair, reconcile.
- `OKDiskService` — thin service executable with an `OperationCoordinator` actor wrapper.
- `okdiskctl` — JSON-capable CLI used by e2e tests.
- `OKDiskCoreTests` / `OKDiskE2ETests` — executable test runners because this host toolchain does not provide XCTest.

## Scripts

```bash
./scripts/build.sh
./scripts/test.sh
./scripts/test-e2e.sh
```

## CLI smoke flow

```bash
ROOT=$(mktemp -d /tmp/okdisk-e2e.XXXXXX)
mkdir -p "$ROOT/src/Documents"
echo hello > "$ROOT/src/Documents/a.txt"
.build/debug/okdiskctl --config "$ROOT/config/destinations.json" --json destinations attach "$ROOT/dest-a"
.build/debug/okdiskctl --config "$ROOT/config/destinations.json" --json destinations attach "$ROOT/dest-b"
.build/debug/okdiskctl --config "$ROOT/config/destinations.json" --json folders add "$ROOT/src/Documents" --replicas 2 --large-file-threshold 1024
.build/debug/okdiskctl --config "$ROOT/config/destinations.json" --json backup --all
.build/debug/okdiskctl --config "$ROOT/config/destinations.json" --json verify --deep
```
