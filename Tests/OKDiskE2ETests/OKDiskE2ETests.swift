import Darwin
import Foundation
import OKDiskCore

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(message: message) }
}

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) throws {
    if lhs != rhs { throw TestFailure(message: "\(message) — left: \(lhs), right: \(rhs)") }
}

func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw TestFailure(message: message) }
    return value
}

func expectThrows(_ message: String, _ operation: () async throws -> Void) async throws -> Error {
    do {
        try await operation()
    } catch {
        return error
    }
    throw TestFailure(message: message)
}

@main
struct OKDiskE2ETestRunner {
    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("backup/restore/verify/incremental metadata path", testBackupRestoreVerifyIncrementalAndMetadata),
            ("initial replica placement randomly selects destinations", testInitialReplicaPlacementRandomlySelectsDestinations),
            ("interrupted run self-corrects and repair uses healthy replica", testInterruptedRunSelfCorrectsAndRepairUsesHealthyReplica),
            ("log mismatch blocks backup until confirmed reconcile", testLogMismatchBlocksBackupUntilConfirmedReconcile),
            ("destination prune removes trees no longer linked to source replicas", testDestinationPruneRemovesUnlinkedTrees),
            ("config isolation between two services", testConfigIsolationBetweenTwoServices)
        ]

        var failures = 0
        for (name, test) in tests {
            do {
                try await test()
                print("✓ \(name)")
            } catch {
                failures += 1
                print("✗ \(name): \(error)")
            }
        }
        if failures > 0 {
            print("\n\(failures) e2e test(s) failed")
            exit(1)
        }
        print("\nAll e2e tests passed")
    }

    static func testBackupRestoreVerifyIncrementalAndMetadata() async throws {
        let root = try makeTempRoot("happy-path")
        let config = root + "/config/destinations.json"
        let source = root + "/src/Documents"
        let destA = root + "/destinations/dest-a"
        let destB = root + "/destinations/dest-b"
        let restore = root + "/restore"
        try createFixture(at: source)

        let service = OKDiskService(configPath: config, hostname: "e2e-host", environment: .test)
        _ = try await service.attachDestination(.init(rootPath: destA))
        _ = try await service.attachDestination(.init(rootPath: destB))
        let folder = try await service.addFolder(.init(sourcePath: source, replicaCount: 2))

        let backupID = try await service.startBackup(folderID: nil)
        let backup = await service.getOperation(backupID)
        try expectEqual(backup?.state, .succeeded, "initial backup should succeed")
        try expectEqual(backup?.summary?.filesDeleted, 0, "initial backup should not delete files")

        let treeA = okdiskTreeRoot(destinationRoot: destA, hostname: folder.hostname, folderID: folder.folderID)
        let treeB = okdiskTreeRoot(destinationRoot: destB, hostname: folder.hostname, folderID: folder.folderID)
        try expectTreesMatch(sourceRoot: source, treeRoot: treeA, excludedPatterns: folder.excludedPatterns)
        try expectTreesMatch(sourceRoot: source, treeRoot: treeB, excludedPatterns: folder.excludedPatterns)
        try assertMetadataContainsOnlyControlEvents(destinationRoot: destA)
        try assertMetadataContainsOnlyControlEvents(destinationRoot: destB)

        let verifyID = try await service.startVerification(.init(deep: true))
        let verify = await service.getOperation(verifyID)
        try expectEqual(verify?.state, .succeeded, "verification operation should succeed")
        try expect(verify?.verifyReport?.isHealthy == true, "deep verification should be healthy: \(verify?.verifyReport?.issues.description ?? "missing report")")

        let fullRestoreID = try await service.startRestore(.init(folderID: folder.folderID, destinationPath: restore))
        let fullOutput = try unwrap((await service.getOperation(fullRestoreID))?.summary?.outputPath, "full restore should return output path")
        try expectTreesMatch(sourceRoot: source, treeRoot: fullOutput, excludedPatterns: folder.excludedPatterns)

        let subRestoreID = try await service.startRestore(.init(folderID: folder.folderID, destinationPath: restore, scope: .subfolder, relativePath: "nested"))
        let subOutput = try unwrap((await service.getOperation(subRestoreID))?.summary?.outputPath, "subfolder restore should return output path")
        try expect(FileManager.default.fileExists(atPath: subOutput + "/nested/b.txt"), "subfolder restore should include nested/b.txt")
        try expect(!FileManager.default.fileExists(atPath: subOutput + "/a.txt"), "subfolder restore should not include a.txt")

        let fileRestoreID = try await service.startRestore(.init(folderID: folder.folderID, destinationPath: restore, scope: .singleFile, relativePath: "a.txt"))
        let fileOutput = try unwrap((await service.getOperation(fileRestoreID))?.summary?.outputPath, "file restore should return output path")
        try expectEqual(try String(contentsOfFile: fileOutput + "/a.txt", encoding: .utf8), "hello\n", "single file restore should match content")

        try "hello modified\n".write(toFile: source + "/a.txt", atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: source + "/nested/b.txt")
        try "new file\n".write(toFile: source + "/nested/new.txt", atomically: true, encoding: .utf8)

        let incrementalID = try await service.startBackup(folderID: folder.folderID)
        let incremental = await service.getOperation(incrementalID)
        try expectEqual(incremental?.state, .succeeded, "incremental backup should succeed")
        try expect((incremental?.summary?.filesMirrored ?? 0) >= 2, "incremental should mirror changed files")
        try expect((incremental?.summary?.filesDeleted ?? 0) >= 2, "incremental should delete stale files on both replicas")
        try expectTreesMatch(sourceRoot: source, treeRoot: treeA, excludedPatterns: folder.excludedPatterns)
        try expectTreesMatch(sourceRoot: source, treeRoot: treeB, excludedPatterns: folder.excludedPatterns)

        let finalVerifyID = try await service.startVerification(.init(deep: true))
        let finalVerify = await service.getOperation(finalVerifyID)
        try expect(finalVerify?.verifyReport?.isHealthy == true, "final verification should be healthy: \(finalVerify?.verifyReport?.issues.description ?? "missing report")")
    }

    static func testInitialReplicaPlacementRandomlySelectsDestinations() async throws {
        let root = try makeTempRoot("random-replicas")
        let config = root + "/config/destinations.json"
        let sourceA = root + "/src/Documents-A"
        let sourceB = root + "/src/Documents-B"
        let destA = root + "/dest-a"
        let destB = root + "/dest-b"
        let destC = root + "/dest-c"
        try createFixture(at: sourceA)
        try createFixture(at: sourceB)
        try "second source\n".write(toFile: sourceB + "/only-b.txt", atomically: true, encoding: .utf8)

        let service = OKDiskService(configPath: config, hostname: "random-host", environment: .test)
        _ = try await service.attachDestination(.init(rootPath: destA))
        _ = try await service.attachDestination(.init(rootPath: destB))
        _ = try await service.attachDestination(.init(rootPath: destC))
        let folderA = try await service.addFolder(.init(sourcePath: sourceA, replicaCount: 2))
        let folderB = try await service.addFolder(.init(sourcePath: sourceB, replicaCount: 2))
        let replicaIDsA = try replicaStoreIDs(folderA)
        let replicaIDsB = try replicaStoreIDs(folderB)

        let destinations = try await service.listDestinations()
        let rootByStoreID = Dictionary(uniqueKeysWithValues: try destinations.map { destination -> (String, String) in
            guard let storeID = destination.storeID else { throw TestFailure(message: "destination should have store ID") }
            return (storeID, destination.rootPath)
        })
        let storeIDs = Set(rootByStoreID.keys)
        for replicaIDs in [replicaIDsA, replicaIDsB] {
            try expectEqual(replicaIDs.count, 2, "folder should select the requested replica count")
            try expectEqual(Set(replicaIDs).count, 2, "folder should not select the same destination twice")
            try expect(Set(replicaIDs).isSubset(of: storeIDs), "selected replicas should be attached destinations")
        }

        let listedFolders = try await service.listFolders()
        try expectEqual(listedFolders.first { $0.folderID == folderA.folderID }?.replicaStoreIDs, replicaIDsA, "replica placement should replay from metadata")
        try expectEqual(listedFolders.first { $0.folderID == folderB.folderID }?.replicaStoreIDs, replicaIDsB, "replica placement should replay from metadata")

        let backupID = try await service.startBackup(folderID: nil)
        try expectEqual((await service.getOperation(backupID))?.state, .succeeded, "random replica backup should succeed")

        for folder in [folderA, folderB] {
            let selectedStoreIDs = Set(try replicaStoreIDs(folder))
            for (storeID, destinationRoot) in rootByStoreID {
                let tree = okdiskTreeRoot(destinationRoot: destinationRoot, hostname: folder.hostname, folderID: folder.folderID)
                if selectedStoreIDs.contains(storeID) {
                    try expectTreesMatch(sourceRoot: folder.sourcePath, treeRoot: tree, excludedPatterns: folder.excludedPatterns)
                } else {
                    try expect(!FileManager.default.fileExists(atPath: tree), "unselected destination should not receive payload tree")
                }
            }
        }
    }

    static func testInterruptedRunSelfCorrectsAndRepairUsesHealthyReplica() async throws {
        let root = try makeTempRoot("crash-repair")
        let config = root + "/config/destinations.json"
        let source = root + "/src/Documents"
        let destA = root + "/dest-a"
        let destB = root + "/dest-b"
        try createFixture(at: source)
        try "larger payload\n".write(toFile: source + "/nested/large.txt", atomically: true, encoding: .utf8)

        let service = OKDiskService(configPath: config, hostname: "repair-host", environment: .test)
        _ = try await service.attachDestination(.init(rootPath: destA))
        _ = try await service.attachDestination(.init(rootPath: destB))
        let folder = try await service.addFolder(.init(sourcePath: source, replicaCount: 2))

        let faultError = try await expectThrows("fault-injected backup should fail") {
            _ = try await service.startBackup(.init(folderID: folder.folderID, fault: .afterPayloadWrites(2)))
        }
        guard case OKDiskError.faultInjected = faultError else {
            throw TestFailure(message: "expected faultInjected, got \(faultError)")
        }

        let recoveryID = try await service.startBackup(folderID: folder.folderID)
        try expectEqual((await service.getOperation(recoveryID))?.state, .succeeded, "recovery backup should succeed")
        let treeA = okdiskTreeRoot(destinationRoot: destA, hostname: folder.hostname, folderID: folder.folderID)
        let treeB = okdiskTreeRoot(destinationRoot: destB, hostname: folder.hostname, folderID: folder.folderID)
        try expectTreesMatch(sourceRoot: source, treeRoot: treeA, excludedPatterns: folder.excludedPatterns)
        try expectTreesMatch(sourceRoot: source, treeRoot: treeB, excludedPatterns: folder.excludedPatterns)

        try FileManager.default.removeItem(atPath: treeA + "/nested/large.txt")
        let brokenVerifyID = try await service.startVerification(.init(deep: true))
        let issues = (await service.getOperation(brokenVerifyID))?.verifyReport?.issues ?? []
        try expect(issues.contains { $0.kind == "missing" && $0.relativePath == "nested/large.txt" }, "verification should report missing large file")

        let repairID = try await service.startRepair(.init(folderID: folder.folderID, confirmed: true))
        try expectEqual((await service.getOperation(repairID))?.state, .succeeded, "repair should succeed")
        try expectTreesMatch(sourceRoot: source, treeRoot: treeA, excludedPatterns: folder.excludedPatterns)

        let healthyID = try await service.startVerification(.init(deep: true))
        let healthy = await service.getOperation(healthyID)
        try expect(healthy?.verifyReport?.isHealthy == true, "post-repair verification should be healthy: \(healthy?.verifyReport?.issues.description ?? "missing report")")
    }

    static func testLogMismatchBlocksBackupUntilConfirmedReconcile() async throws {
        let root = try makeTempRoot("reconcile")
        let config = root + "/config/destinations.json"
        let source = root + "/src/Documents"
        let destA = root + "/dest-a"
        let destB = root + "/dest-b"
        try createFixture(at: source)

        let service = OKDiskService(configPath: config, hostname: "reconcile-host", environment: .test)
        _ = try await service.attachDestination(.init(rootPath: destA))
        _ = try await service.attachDestination(.init(rootPath: destB))
        let folder = try await service.addFolder(.init(sourcePath: source, replicaCount: 2))
        _ = try await service.startBackup(folderID: folder.folderID)

        try removeLastMetadataLine(destinationRoot: destB)
        let conflictStatus = await service.getStatus()
        try expectEqual(conflictStatus.state, "attention_needed", "status should need attention")
        try expect(!conflictStatus.conflicts.isEmpty, "conflicts should be reported")

        let blocked = try await expectThrows("backup should be blocked by mismatched logs") {
            _ = try await service.startBackup(folderID: folder.folderID)
        }
        guard case OKDiskError.conflictsBlocked(let conflicts) = blocked else {
            throw TestFailure(message: "expected conflictsBlocked, got \(blocked)")
        }
        try expect(!conflicts.isEmpty, "blocked error should include conflicts")

        let reconcileID = try await service.confirmUpdateDestinationsToLatest(.init(confirmed: true))
        try expectEqual((await service.getOperation(reconcileID))?.state, .succeeded, "reconcile should succeed")
        let reconciledStatus = await service.getStatus()
        try expect(reconciledStatus.conflicts.isEmpty, "conflicts should clear after reconcile")
        try assertLogContains(destinationRoot: destA, eventType: MetadataEventType.stateReconcile)
        try assertLogContains(destinationRoot: destB, eventType: MetadataEventType.stateReconcile)

        try "after reconcile\n".write(toFile: source + "/after.txt", atomically: true, encoding: .utf8)
        let backupID = try await service.startBackup(folderID: folder.folderID)
        try expectEqual((await service.getOperation(backupID))?.state, .succeeded, "backup should work after reconcile")
    }

    static func testDestinationPruneRemovesUnlinkedTrees() async throws {
        let root = try makeTempRoot("prune-unlinked")
        let config = root + "/config/destinations.json"
        let source = root + "/src/Documents"
        let destA = root + "/dest-a"
        let destB = root + "/dest-b"
        let destC = root + "/dest-c"
        try createFixture(at: source)

        let service = OKDiskService(configPath: config, hostname: "prune-host", environment: .test)
        _ = try await service.attachDestination(.init(rootPath: destA))
        _ = try await service.attachDestination(.init(rootPath: destB))
        _ = try await service.attachDestination(.init(rootPath: destC))
        let folder = try await service.addFolder(.init(sourcePath: source, replicaCount: 3))
        let initialStatuses = try await service.listDestinations()
        let destCStoreID = try unwrap(
            initialStatuses.first { $0.canonicalRootPath == okdiskCanonicalExistingPath(destC) }?.storeID,
            "third destination should have a store ID"
        )

        let initialBackupID = try await service.startBackup(folderID: folder.folderID)
        try expectEqual((await service.getOperation(initialBackupID))?.state, .succeeded, "initial three-replica backup should succeed")
        let treeA = okdiskTreeRoot(destinationRoot: destA, hostname: folder.hostname, folderID: folder.folderID)
        let treeB = okdiskTreeRoot(destinationRoot: destB, hostname: folder.hostname, folderID: folder.folderID)
        let treeC = okdiskTreeRoot(destinationRoot: destC, hostname: folder.hostname, folderID: folder.folderID)
        try expectTreesMatch(sourceRoot: source, treeRoot: treeA, excludedPatterns: folder.excludedPatterns)
        try expectTreesMatch(sourceRoot: source, treeRoot: treeB, excludedPatterns: folder.excludedPatterns)
        try expectTreesMatch(sourceRoot: source, treeRoot: treeC, excludedPatterns: folder.excludedPatterns)

        try await service.removeDestination(rootPath: destC)
        let blocked = try await expectThrows("backup should fail while a required replica destination is removed") {
            _ = try await service.startBackup(folderID: folder.folderID)
        }
        guard case OKDiskError.insufficientReplicas(let required, let available) = blocked else {
            throw TestFailure(message: "expected insufficientReplicas after removing destination, got \(blocked)")
        }
        try expectEqual(required, 3, "blocked backup should still require three replicas")
        try expectEqual(available, 2, "only two destinations should be available after removing one")

        try "after reducing replicas\n".write(toFile: source + "/after-reduction.txt", atomically: true, encoding: .utf8)
        let updatedFolder = try await service.updateFolder(.init(folderID: folder.folderID, replicaCount: 2))
        try expectEqual(updatedFolder.replicaCount, 2, "folder should now require two replicas")
        try expect(!(updatedFolder.replicaStoreIDs ?? []).contains(destCStoreID), "updated folder should not target removed destination")
        let reducedBackupID = try await service.startBackup(folderID: folder.folderID)
        try expectEqual((await service.getOperation(reducedBackupID))?.state, .succeeded, "backup should succeed after reducing replicas")
        try expectTreesMatch(sourceRoot: source, treeRoot: treeA, excludedPatterns: updatedFolder.excludedPatterns)
        try expectTreesMatch(sourceRoot: source, treeRoot: treeB, excludedPatterns: updatedFolder.excludedPatterns)
        try expect(!FileManager.default.fileExists(atPath: treeC + "/after-reduction.txt"), "removed destination should not receive reduced-replica backup payloads")

        _ = try await service.attachDestination(.init(rootPath: destC))
        let staleStatus = await service.getStatus()
        try expect(!staleStatus.conflicts.isEmpty, "reattached destination should be stale before reconcile")
        let reconcileID = try await service.confirmUpdateDestinationsToLatest(.init(confirmed: true))
        try expectEqual((await service.getOperation(reconcileID))?.state, .succeeded, "reconcile should update stale destination metadata")
        let reconciledStatus = await service.getStatus()
        try expect(reconciledStatus.conflicts.isEmpty, "conflicts should clear after reconcile")

        try "after reattach\n".write(toFile: source + "/after-reattach.txt", atomically: true, encoding: .utf8)
        try expect(FileManager.default.fileExists(atPath: treeC), "old unlinked tree should still exist before prune")
        let reattachedBackupID = try await service.startBackup(folderID: folder.folderID)
        try expectEqual((await service.getOperation(reattachedBackupID))?.state, .succeeded, "backup should succeed after reattach and reconcile")
        try expectTreesMatch(sourceRoot: source, treeRoot: treeA, excludedPatterns: updatedFolder.excludedPatterns)
        try expectTreesMatch(sourceRoot: source, treeRoot: treeB, excludedPatterns: updatedFolder.excludedPatterns)
        try expect(!FileManager.default.fileExists(atPath: treeC + "/after-reduction.txt"), "reattached destination should not receive older two-replica payloads")
        try expect(!FileManager.default.fileExists(atPath: treeC + "/after-reattach.txt"), "reattached destination should not receive new payloads when no longer selected")

        let pruneID = try await service.startPruneDestination(.init(destinationRootPath: destC, confirmed: true))
        let prune = await service.getOperation(pruneID)
        try expectEqual(prune?.state, .succeeded, "prune operation should succeed")
        try expectEqual(prune?.summary?.prunedTrees, 1, "prune should remove exactly the unlinked tree")
        try expect(!FileManager.default.fileExists(atPath: treeC), "prune should remove the old unlinked tree")
        try expectTreesMatch(sourceRoot: source, treeRoot: treeA, excludedPatterns: updatedFolder.excludedPatterns)
        try expectTreesMatch(sourceRoot: source, treeRoot: treeB, excludedPatterns: updatedFolder.excludedPatterns)

        let verifyID = try await service.startVerification(.init(deep: true))
        let verify = await service.getOperation(verifyID)
        try expect(verify?.verifyReport?.isHealthy == true, "verification should remain healthy after prune: \(verify?.verifyReport?.issues.description ?? "missing report")")

        try "after prune\n".write(toFile: source + "/after-prune.txt", atomically: true, encoding: .utf8)
        let postPruneBackupID = try await service.startBackup(folderID: folder.folderID)
        try expectEqual((await service.getOperation(postPruneBackupID))?.state, .succeeded, "backup should still succeed after prune")
        try expect(!FileManager.default.fileExists(atPath: treeC), "pruned destination should not get a tree recreated by later backups")
        try expectTreesMatch(sourceRoot: source, treeRoot: treeA, excludedPatterns: updatedFolder.excludedPatterns)
        try expectTreesMatch(sourceRoot: source, treeRoot: treeB, excludedPatterns: updatedFolder.excludedPatterns)
    }

    static func testConfigIsolationBetweenTwoServices() async throws {
        let rootA = try makeTempRoot("isolation-a")
        let rootB = try makeTempRoot("isolation-b")
        let sourceA = rootA + "/src"
        let sourceB = rootB + "/src"
        try FileManager.default.createDirectory(atPath: sourceA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: sourceB, withIntermediateDirectories: true)
        try "a\n".write(toFile: sourceA + "/only-a.txt", atomically: true, encoding: .utf8)
        try "b\n".write(toFile: sourceB + "/only-b.txt", atomically: true, encoding: .utf8)

        let serviceA = OKDiskService(configPath: rootA + "/config/destinations.json", hostname: "host-a", environment: .test)
        let serviceB = OKDiskService(configPath: rootB + "/config/destinations.json", hostname: "host-b", environment: .test)
        _ = try await serviceA.attachDestination(.init(rootPath: rootA + "/dest"))
        _ = try await serviceB.attachDestination(.init(rootPath: rootB + "/dest"))
        let folderA = try await serviceA.addFolder(.init(sourcePath: sourceA, replicaCount: 1))
        let folderB = try await serviceB.addFolder(.init(sourcePath: sourceB, replicaCount: 1))
        _ = try await serviceA.startBackup(folderID: nil)
        _ = try await serviceB.startBackup(folderID: nil)

        try expect(folderA.folderID != folderB.folderID, "folder IDs should differ")
        try expectEqual(try await serviceA.listDestinations().count, 1, "service A should have one destination")
        try expectEqual(try await serviceB.listDestinations().count, 1, "service B should have one destination")
        try expectEqual(try await serviceA.listFolders().map(\.folderID), [folderA.folderID], "service A should see only folder A")
        try expectEqual(try await serviceB.listFolders().map(\.folderID), [folderB.folderID], "service B should see only folder B")
    }

    static func makeTempRoot(_ name: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("okdisk-e2e-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    static func createFixture(at source: String) throws {
        try FileManager.default.createDirectory(atPath: source + "/nested/deep", withIntermediateDirectories: true)
        try "hello\n".write(toFile: source + "/a.txt", atomically: true, encoding: .utf8)
        try "nested\n".write(toFile: source + "/nested/b.txt", atomically: true, encoding: .utf8)
        try "deep\n".write(toFile: source + "/nested/deep/c.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: source + "/link-to-a", withDestinationPath: "a.txt")
        try ".ignored\n".write(toFile: source + "/.DS_Store", atomically: true, encoding: .utf8)
    }

    static func replicaStoreIDs(_ folder: FolderConfig) throws -> [String] {
        guard let replicaStoreIDs = folder.replicaStoreIDs else {
            throw TestFailure(message: "folder should store selected replica destination IDs")
        }
        try expectEqual(replicaStoreIDs.count, folder.replicaCount, "replica store ID count should match replica count")
        try expectEqual(Set(replicaStoreIDs).count, replicaStoreIDs.count, "replica store IDs should be unique")
        return replicaStoreIDs
    }

    static func assertMetadataContainsOnlyControlEvents(destinationRoot: String) throws {
        try assertLogContains(destinationRoot: destinationRoot, eventType: MetadataEventType.folderUpsert)
        try assertLogContains(destinationRoot: destinationRoot, eventType: MetadataEventType.syncRunStart)
        try assertLogContains(destinationRoot: destinationRoot, eventType: MetadataEventType.syncRunEnd)
        let log = try String(contentsOfFile: okdiskCanonicalExistingPath(destinationRoot) + "/okdisk.metadata.jsonl", encoding: .utf8)
        try expect(!log.contains("file.upsert"), "metadata log should not contain file.upsert")
        try expect(!log.contains("file.delete"), "metadata log should not contain file.delete")
    }

    static func assertLogContains(destinationRoot: String, eventType: String) throws {
        let log = try String(contentsOfFile: okdiskCanonicalExistingPath(destinationRoot) + "/okdisk.metadata.jsonl", encoding: .utf8)
        try expect(log.contains("\"event_type\":\"\(eventType)\""), "missing \(eventType) in log")
    }

    static func removeLastMetadataLine(destinationRoot: String) throws {
        let path = okdiskCanonicalExistingPath(destinationRoot) + "/okdisk.metadata.jsonl"
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last == "" { lines.removeLast() }
        try expect(!lines.isEmpty, "metadata log should not be empty")
        lines.removeLast()
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

enum TestNodeKind: Equatable {
    case directory
    case regularFile
    case symlink(String)
}

struct TestNode: Equatable {
    var relativePath: String
    var kind: TestNodeKind
    var data: Data?
}

func expectTreesMatch(sourceRoot: String, treeRoot: String, excludedPatterns: [String]) throws {
    let source = try testSnapshot(rootPath: okdiskCanonicalExistingPath(sourceRoot), skipArtifacts: true, excludedPatterns: excludedPatterns)
    let tree = try testSnapshot(rootPath: okdiskCanonicalExistingPath(treeRoot), skipArtifacts: false, excludedPatterns: [])
    try expectEqual(Set(source.keys), Set(tree.keys), "tree paths should match source")
    for key in source.keys.sorted() {
        let lhs = source[key]!
        let rhs = tree[key]!
        try expectEqual(lhs.kind, rhs.kind, "kind should match for \(key)")
        try expectEqual(lhs.data, rhs.data, "content should match for \(key)")
    }
}

func testSnapshot(rootPath: String, skipArtifacts: Bool, excludedPatterns: [String]) throws -> [String: TestNode] {
    guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: rootPath), includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true }) else {
        throw TestFailure(message: "could not enumerate \(rootPath)")
    }
    var nodes: [String: TestNode] = [:]
    for case let url as URL in enumerator {
        let rel = try relativePath(path: url.path, base: rootPath)
        let node = try testNode(path: url.path, relativePath: rel)
        if skipArtifacts && shouldSkip(rel, excludedPatterns: excludedPatterns) {
            if case .directory = node.kind { enumerator.skipDescendants() }
            continue
        }
        nodes[rel] = node
    }
    return nodes
}

func relativePath(path: String, base: String) throws -> String {
    let prefix = base.hasSuffix("/") ? base : base + "/"
    guard path.hasPrefix(prefix) else { throw TestFailure(message: "\(path) is not under \(base)") }
    return String(path.dropFirst(prefix.count))
}

func shouldSkip(_ rel: String, excludedPatterns: [String]) -> Bool {
    if rel == ".okdisk" || rel.hasPrefix(".okdisk/") { return true }
    if rel == "okdisk.store.json" || rel == "okdisk.metadata.jsonl" { return true }
    if rel == "data" || rel.hasPrefix("data/") || rel == "tmp" || rel.hasPrefix("tmp/") { return true }
    let last = URL(fileURLWithPath: rel).lastPathComponent
    for pattern in excludedPatterns {
        if pattern == rel || pattern == last { return true }
        if pattern.hasSuffix("/**") {
            let prefix = String(pattern.dropLast(3))
            if rel == prefix || rel.hasPrefix(prefix + "/") { return true }
        }
    }
    return false
}

func testNode(path: String, relativePath: String) throws -> TestNode {
    var st = stat()
    if lstat(path, &st) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let type = st.st_mode & S_IFMT
    if type == S_IFDIR { return TestNode(relativePath: relativePath, kind: .directory, data: nil) }
    if type == S_IFLNK {
        return TestNode(relativePath: relativePath, kind: .symlink(try FileManager.default.destinationOfSymbolicLink(atPath: path)), data: nil)
    }
    if type == S_IFREG {
        return TestNode(relativePath: relativePath, kind: .regularFile, data: try Data(contentsOf: URL(fileURLWithPath: path)))
    }
    throw TestFailure(message: "unsupported node at \(path)")
}
