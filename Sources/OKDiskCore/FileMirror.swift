import Darwin
import Foundation

enum FileNodeKind: String, Codable, Equatable {
    case directory
    case regularFile
    case symlink
}

struct FileNode: Codable, Equatable {
    var relativePath: String
    var kind: FileNodeKind
    var size: Int64
    var modifiedAt: Date?
    var symlinkTarget: String?
}

struct Snapshot: Equatable {
    var rootPath: String
    var nodes: [String: FileNode]

    var fileCount: Int {
        nodes.values.filter { $0.kind == .regularFile }.count
    }
}

final class FaultController {
    private let fault: BackupFault?
    private var payloadWrites = 0

    init(fault: BackupFault?) {
        self.fault = fault
    }

    func afterSyncStart() throws {
        guard fault?.mode == BackupFault.afterSyncStart.mode else { return }
        throw OKDiskError.faultInjected("after sync_run.start")
    }

    func beforeSyncEnd() throws {
        guard fault?.mode == BackupFault.beforeSyncEnd.mode else { return }
        throw OKDiskError.faultInjected("before sync_run.end")
    }

    func afterPayloadWrite(relativePath: String) throws {
        guard fault?.mode == "after-payload-writes" else { return }
        payloadWrites += 1
        if let limit = fault?.payloadWriteLimit, payloadWrites >= limit {
            throw OKDiskError.faultInjected("after \(payloadWrites) payload writes at \(relativePath)")
        }
    }
}

enum FileMirror {
    static func snapshotSource(rootPath: String, excludedPatterns: [String]) throws -> Snapshot {
        try snapshot(rootPath: rootPath, excludedPatterns: excludedPatterns, skipOKDiskArtifacts: true)
    }

    static func snapshotTree(rootPath: String) throws -> Snapshot {
        guard okdiskIsDirectory(rootPath) else {
            return Snapshot(rootPath: rootPath, nodes: [:])
        }
        return try snapshot(rootPath: rootPath, excludedPatterns: [], skipOKDiskArtifacts: false)
    }

    static func mirrorSource(
        sourceRoot: String,
        treeRoot: String,
        tmpRoot: String,
        syncRunID: String,
        excludedPatterns: [String],
        fault: FaultController?
    ) throws -> BackupRunSummary {
        let sourceSnapshot = try snapshotSource(rootPath: sourceRoot, excludedPatterns: excludedPatterns)
        return try mirrorSnapshot(
            sourceRoot: okdiskCanonicalExistingPath(sourceRoot),
            sourceSnapshot: sourceSnapshot,
            destinationRoot: treeRoot,
            tmpRoot: tmpRoot,
            syncRunID: syncRunID,
            fault: fault
        )
    }

    static func mirrorTree(
        sourceTreeRoot: String,
        targetTreeRoot: String,
        tmpRoot: String,
        syncRunID: String = UUID().uuidString
    ) throws -> BackupRunSummary {
        let sourceSnapshot = try snapshotTree(rootPath: sourceTreeRoot)
        return try mirrorSnapshot(
            sourceRoot: okdiskCanonicalExistingPath(sourceTreeRoot),
            sourceSnapshot: sourceSnapshot,
            destinationRoot: targetTreeRoot,
            tmpRoot: tmpRoot,
            syncRunID: syncRunID,
            fault: nil
        )
    }

    static func copySubset(
        sourceTreeRoot: String,
        outputRoot: String,
        include: (String, FileNode) -> Bool,
        overwriteConfirmed: Bool
    ) throws -> OperationSummary {
        let snapshot = try snapshotTree(rootPath: sourceTreeRoot)
        try okdiskEnsureDirectory(outputRoot)
        var summary = OperationSummary(outputPath: outputRoot)
        let selected = snapshot.nodes.values.filter { include($0.relativePath, $0) }
        if selected.isEmpty {
            throw OKDiskError.invalidPath("No matching restore paths found")
        }
        for node in selected.sorted(by: restoreSort) {
            let sourcePath = sourceTreeRoot + "/" + node.relativePath
            let destinationPath = outputRoot + "/" + node.relativePath
            let parent = URL(fileURLWithPath: destinationPath).deletingLastPathComponent().path
            try okdiskEnsureDirectory(parent)
            if okdiskPathExists(destinationPath) || lstatExists(destinationPath) {
                guard overwriteConfirmed else { throw OKDiskError.overwriteNotConfirmed(destinationPath) }
                try okdiskRemoveItemIfExists(destinationPath)
            }
            switch node.kind {
            case .directory:
                try okdiskEnsureDirectory(destinationPath)
            case .regularFile:
                try FileManager.default.copyItem(atPath: sourcePath, toPath: destinationPath)
                okdiskFsyncFile(destinationPath)
                summary.filesRestored += 1
                summary.bytesRestored += node.size
            case .symlink:
                let target: String
                if let symlinkTarget = node.symlinkTarget {
                    target = symlinkTarget
                } else {
                    target = try FileManager.default.destinationOfSymbolicLink(atPath: sourcePath)
                }
                try FileManager.default.createSymbolicLink(atPath: destinationPath, withDestinationPath: target)
                summary.filesRestored += 1
            }
        }
        return summary
    }

    static func snapshotsMatch(_ lhsRoot: String, _ rhsRoot: String) throws -> Bool {
        let lhs = try snapshotTree(rootPath: lhsRoot)
        let rhs = try snapshotTree(rootPath: rhsRoot)
        return try snapshotsEquivalent(lhs, rhs, lhsRoot: lhsRoot, rhsRoot: rhsRoot)
    }

    static func snapshotMatchesSource(treeRoot: String, sourceRoot: String, excludedPatterns: [String]) throws -> Bool {
        let source = try snapshotSource(rootPath: sourceRoot, excludedPatterns: excludedPatterns)
        let tree = try snapshotTree(rootPath: treeRoot)
        return try snapshotsEquivalent(source, tree, lhsRoot: okdiskCanonicalExistingPath(sourceRoot), rhsRoot: treeRoot)
    }

    static func compare(expectedRoot: String, expected: Snapshot, actualRoot: String, actual: Snapshot, folderID: String, destinationRoot: String) throws -> [VerificationIssue] {
        var issues: [VerificationIssue] = []
        for (rel, expectedNode) in expected.nodes {
            guard let actualNode = actual.nodes[rel] else {
                issues.append(VerificationIssue(kind: "missing", folderID: folderID, relativePath: rel, destinationRoot: destinationRoot, message: "Missing replica entry \(rel)"))
                continue
            }
            if expectedNode.kind != actualNode.kind {
                issues.append(VerificationIssue(kind: "corrupt", folderID: folderID, relativePath: rel, destinationRoot: destinationRoot, message: "Node kind mismatch for \(rel)"))
                continue
            }
            switch expectedNode.kind {
            case .directory:
                break
            case .symlink:
                if expectedNode.symlinkTarget != actualNode.symlinkTarget {
                    issues.append(VerificationIssue(kind: "corrupt", folderID: folderID, relativePath: rel, destinationRoot: destinationRoot, message: "Symlink target mismatch for \(rel)"))
                }
            case .regularFile:
                if expectedNode.size != actualNode.size {
                    issues.append(VerificationIssue(kind: "corrupt", folderID: folderID, relativePath: rel, destinationRoot: destinationRoot, message: "Size mismatch for \(rel)"))
                } else {
                    let expectedHash = try okdiskSHA256Hex(fileAt: expectedRoot + "/" + rel)
                    let actualHash = try okdiskSHA256Hex(fileAt: actualRoot + "/" + rel)
                    if expectedHash != actualHash {
                        issues.append(VerificationIssue(kind: "corrupt", folderID: folderID, relativePath: rel, destinationRoot: destinationRoot, message: "Hash mismatch for \(rel)"))
                    }
                }
            }
        }
        for rel in actual.nodes.keys where expected.nodes[rel] == nil {
            issues.append(VerificationIssue(kind: "stale", folderID: folderID, relativePath: rel, destinationRoot: destinationRoot, message: "Stale replica entry \(rel)"))
        }
        return issues.sorted { ($0.relativePath ?? "") < ($1.relativePath ?? "") }
    }

    private static func mirrorSnapshot(
        sourceRoot: String,
        sourceSnapshot: Snapshot,
        destinationRoot: String,
        tmpRoot: String,
        syncRunID: String,
        fault: FaultController?
    ) throws -> BackupRunSummary {
        try okdiskEnsureDirectory(destinationRoot)
        try okdiskEnsureDirectory(tmpRoot + "/" + syncRunID)
        let destinationSnapshot = try snapshotTree(rootPath: destinationRoot)
        var summary = BackupRunSummary()

        for node in sourceSnapshot.nodes.values.sorted(by: mirrorSort) {
            let sourcePath = sourceRoot + "/" + node.relativePath
            let destinationPath = destinationRoot + "/" + node.relativePath
            let existing = destinationSnapshot.nodes[node.relativePath]
            switch node.kind {
            case .directory:
                if existing?.kind != .directory {
                    try okdiskRemoveItemIfExists(destinationPath)
                    try okdiskEnsureDirectory(destinationPath)
                    try fault?.afterPayloadWrite(relativePath: node.relativePath)
                } else {
                    try okdiskEnsureDirectory(destinationPath)
                }
            case .regularFile:
                if try regularFilesEqual(sourcePath: sourcePath, destinationPath: destinationPath, expectedSize: node.size) {
                    continue
                }
                try copyRegularFileAtomically(sourcePath: sourcePath, destinationPath: destinationPath, tmpRoot: tmpRoot, syncRunID: syncRunID, relativePath: node.relativePath)
                summary.filesMirrored += 1
                summary.bytesMirrored += node.size
                try fault?.afterPayloadWrite(relativePath: node.relativePath)
            case .symlink:
                let target: String
                if let symlinkTarget = node.symlinkTarget {
                    target = symlinkTarget
                } else {
                    target = try FileManager.default.destinationOfSymbolicLink(atPath: sourcePath)
                }
                if existing?.kind == .symlink, existing?.symlinkTarget == target { continue }
                try okdiskRemoveItemIfExists(destinationPath)
                let parent = URL(fileURLWithPath: destinationPath).deletingLastPathComponent().path
                try okdiskEnsureDirectory(parent)
                try FileManager.default.createSymbolicLink(atPath: destinationPath, withDestinationPath: target)
                summary.filesMirrored += 1
                try fault?.afterPayloadWrite(relativePath: node.relativePath)
            }
        }

        let sourcePaths = Set(sourceSnapshot.nodes.keys)
        for node in destinationSnapshot.nodes.values.sorted(by: deleteSort) where !sourcePaths.contains(node.relativePath) {
            try okdiskRemoveItemIfExists(destinationRoot + "/" + node.relativePath)
            if node.kind != .directory { summary.filesDeleted += 1 }
            try fault?.afterPayloadWrite(relativePath: node.relativePath)
        }
        okdiskFsyncDirectory(destinationRoot)
        return summary
    }

    private static func snapshot(rootPath: String, excludedPatterns: [String], skipOKDiskArtifacts: Bool) throws -> Snapshot {
        let fm = FileManager.default
        let canonicalRoot = okdiskCanonicalExistingPath(rootPath)
        guard okdiskIsDirectory(canonicalRoot) else {
            throw OKDiskError.sourceUnavailable(rootPath)
        }
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: canonicalRoot), includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true }) else {
            throw OKDiskError.sourceUnavailable(rootPath)
        }
        var nodes: [String: FileNode] = [:]
        for case let url as URL in enumerator {
            let path = url.path
            let rel = try relativePath(path: path, base: canonicalRoot)
            let info = try nodeInfo(path: path)
            if skipOKDiskArtifacts && okdiskShouldSkipRelativePath(rel, excludedPatterns: excludedPatterns) {
                if info.kind == .directory { enumerator.skipDescendants() }
                continue
            }
            nodes[rel] = FileNode(relativePath: rel, kind: info.kind, size: info.size, modifiedAt: info.modifiedAt, symlinkTarget: info.symlinkTarget)
        }
        return Snapshot(rootPath: canonicalRoot, nodes: nodes)
    }

    private static func relativePath(path: String, base: String) throws -> String {
        let standardPath = okdiskStandardPath(path)
        let standardBase = okdiskStandardPath(base)
        let prefix = standardBase.hasSuffix("/") ? standardBase : standardBase + "/"
        guard standardPath.hasPrefix(prefix) else {
            throw OKDiskError.invalidPath("Path \(standardPath) is not under \(standardBase)")
        }
        return try okdiskValidateRelativePath(String(standardPath.dropFirst(prefix.count)))
    }

    private static func nodeInfo(path: String) throws -> (kind: FileNodeKind, size: Int64, modifiedAt: Date?, symlinkTarget: String?) {
        var statBuffer = stat()
        if lstat(path, &statBuffer) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let mode = statBuffer.st_mode
        let type = mode & S_IFMT
        let modified = Date(timeIntervalSince1970: TimeInterval(statBuffer.st_mtimespec.tv_sec) + TimeInterval(statBuffer.st_mtimespec.tv_nsec) / 1_000_000_000)
        if type == S_IFDIR {
            return (.directory, 0, modified, nil)
        }
        if type == S_IFLNK {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
            return (.symlink, Int64(statBuffer.st_size), modified, target)
        }
        if type == S_IFREG {
            return (.regularFile, Int64(statBuffer.st_size), modified, nil)
        }
        throw OKDiskError.invalidPath("Unsupported file type at \(path)")
    }

    private static func regularFilesEqual(sourcePath: String, destinationPath: String, expectedSize: Int64) throws -> Bool {
        guard lstatExists(destinationPath) else { return false }
        let destInfo = try nodeInfo(path: destinationPath)
        guard destInfo.kind == .regularFile, destInfo.size == expectedSize else { return false }
        return try okdiskSHA256Hex(fileAt: sourcePath) == okdiskSHA256Hex(fileAt: destinationPath)
    }

    private static func snapshotsEquivalent(_ lhs: Snapshot, _ rhs: Snapshot, lhsRoot: String, rhsRoot: String) throws -> Bool {
        guard Set(lhs.nodes.keys) == Set(rhs.nodes.keys) else { return false }
        for rel in lhs.nodes.keys {
            guard let left = lhs.nodes[rel], let right = rhs.nodes[rel], left.kind == right.kind else { return false }
            switch left.kind {
            case .directory:
                continue
            case .symlink:
                if left.symlinkTarget != right.symlinkTarget { return false }
            case .regularFile:
                if left.size != right.size { return false }
                if try okdiskSHA256Hex(fileAt: lhsRoot + "/" + rel) != okdiskSHA256Hex(fileAt: rhsRoot + "/" + rel) { return false }
            }
        }
        return true
    }

    private static func copyRegularFileAtomically(sourcePath: String, destinationPath: String, tmpRoot: String, syncRunID: String, relativePath: String) throws {
        let destinationParent = URL(fileURLWithPath: destinationPath).deletingLastPathComponent().path
        try okdiskEnsureDirectory(destinationParent)
        let components = relativePath.split(separator: "/").map(String.init)
        let relativeParent = components.dropLast().joined(separator: "/")
        let tmpParent = relativeParent.isEmpty ? tmpRoot + "/" + syncRunID : tmpRoot + "/" + syncRunID + "/" + relativeParent
        try okdiskEnsureDirectory(tmpParent)
        let fileName = components.last ?? URL(fileURLWithPath: relativePath).lastPathComponent
        let tmpPath = tmpParent + "/.\(fileName).tmp-\(UUID().uuidString)"
        try? okdiskRemoveItemIfExists(tmpPath)
        try FileManager.default.copyItem(atPath: sourcePath, toPath: tmpPath)
        okdiskFsyncFile(tmpPath)
        try okdiskRemoveItemIfExists(destinationPath)
        if rename(tmpPath, destinationPath) != 0 {
            let err = errno
            try? okdiskRemoveItemIfExists(tmpPath)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        okdiskFsyncDirectory(destinationParent)
    }

    private static func mirrorSort(_ lhs: FileNode, _ rhs: FileNode) -> Bool {
        if lhs.kind == .directory && rhs.kind != .directory { return true }
        if lhs.kind != .directory && rhs.kind == .directory { return false }
        return lhs.relativePath < rhs.relativePath
    }

    private static func restoreSort(_ lhs: FileNode, _ rhs: FileNode) -> Bool {
        mirrorSort(lhs, rhs)
    }

    private static func deleteSort(_ lhs: FileNode, _ rhs: FileNode) -> Bool {
        let lc = lhs.relativePath.split(separator: "/").count
        let rc = rhs.relativePath.split(separator: "/").count
        if lc == rc { return lhs.relativePath > rhs.relativePath }
        return lc > rc
    }

    private static func lstatExists(_ path: String) -> Bool {
        var statBuffer = stat()
        return lstat(path, &statBuffer) == 0
    }
}

func lstatExists(_ path: String) -> Bool {
    var statBuffer = stat()
    return lstat(path, &statBuffer) == 0
}
