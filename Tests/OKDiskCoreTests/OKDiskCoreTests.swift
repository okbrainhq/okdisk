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

func expectThrows(_ message: String, _ operation: () async throws -> Void) async throws {
    do {
        try await operation()
    } catch {
        return
    }
    throw TestFailure(message: message)
}

@main
struct OKDiskCoreTestRunner {
    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("folder ID uses hostname and canonical path", testFolderIDUsesHostnameAndCanonicalPath),
            ("restore rejects traversal paths", testRestoreRejectsTraversalPaths),
            ("metadata replay tolerates partial last line and reports corrupt line", testMetadataReplayStatus),
            ("destination config stores only roots", testDestinationConfigStoresOnlyRoots)
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
            print("\n\(failures) core test(s) failed")
            exit(1)
        }
        print("\nAll core tests passed")
    }

    static func testFolderIDUsesHostnameAndCanonicalPath() async throws {
        let root = try makeTempRoot()
        let source = root + "/src"
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)

        let canonical = okdiskCanonicalExistingPath(source)
        let idA = okdiskFolderID(hostname: "host-a", sourcePath: canonical)
        let idAAgain = okdiskFolderID(hostname: "HOST-A", sourcePath: source)
        let idB = okdiskFolderID(hostname: "host-b", sourcePath: canonical)

        try expectEqual(idA, idAAgain, "same hostname/path should produce same folder ID")
        try expect(idA != idB, "different hostname should produce different folder ID")
    }

    static func testRestoreRejectsTraversalPaths() async throws {
        let root = try makeTempRoot()
        let service = OKDiskService(configPath: root + "/config/destinations.json", hostname: "core-host", environment: .test)
        let source = root + "/src"
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        try "hello".write(toFile: source + "/a.txt", atomically: true, encoding: .utf8)
        _ = try await service.attachDestination(.init(rootPath: root + "/dest"))
        let folder = try await service.addFolder(.init(sourcePath: source, replicaCount: 1))
        _ = try await service.startBackup(folderID: folder.folderID)

        try await expectThrows("restore should reject ../ traversal") {
            _ = try await service.startRestore(.init(folderID: folder.folderID, destinationPath: root + "/restore", scope: .singleFile, relativePath: "../secret.txt"))
        }
        try await expectThrows("restore should reject absolute paths") {
            _ = try await service.startRestore(.init(folderID: folder.folderID, destinationPath: root + "/restore", scope: .singleFile, relativePath: "/absolute.txt"))
        }
    }

    static func testMetadataReplayStatus() async throws {
        let root = try makeTempRoot()
        let service = OKDiskService(configPath: root + "/config/destinations.json", hostname: "core-host", environment: .test)
        _ = try await service.attachDestination(.init(rootPath: root + "/dest"))
        let log = okdiskCanonicalExistingPath(root + "/dest") + "/okdisk.metadata.jsonl"

        try "{partial".write(toFile: log, atomically: true, encoding: .utf8)
        var status = try await service.listDestinations()[0]
        try expectEqual(status.state, .healthy, "partial final record should not corrupt destination")
        try expect(status.skippedPartialRecord, "partial final record should be reported")
        try expectEqual(status.skippedCorruptRecords, 0, "partial final record should not count as corrupt")

        try "{bad}\n".write(toFile: log, atomically: true, encoding: .utf8)
        status = try await service.listDestinations()[0]
        try expectEqual(status.state, .corrupted, "complete malformed record should mark destination corrupted")
        try expectEqual(status.skippedCorruptRecords, 1, "corrupt complete record should be counted")
    }

    static func testDestinationConfigStoresOnlyRoots() async throws {
        let root = try makeTempRoot()
        let configPath = root + "/config/destinations.json"
        let service = OKDiskService(configPath: configPath, hostname: "core-host", environment: .test)
        _ = try await service.attachDestination(.init(rootPath: root + "/dest-a"))
        _ = try await service.attachDestination(.init(rootPath: root + "/dest-b"))
        try await expectThrows("duplicate destination should be rejected") {
            _ = try await service.attachDestination(.init(rootPath: root + "/dest-a"))
        }

        let raw = try String(contentsOfFile: configPath, encoding: .utf8)
        try expect(raw.contains("destination_roots"), "config should contain destination_roots")
        try expect(!raw.contains("source_path"), "config must not contain source paths")
        try expect(!raw.contains("folder_id"), "config must not contain folder IDs")
    }

    static func makeTempRoot() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("okdisk-core-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
