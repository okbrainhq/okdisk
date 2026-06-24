import Foundation

struct LoadedState {
    var config: DestinationConfig
    var connected: [DestinationContext]
    var statuses: [DestinationStatus]
    var conflicts: [DestinationStateConflict]
    var reference: DestinationContext?
    var folders: [String: FolderConfig]

    var activeFolders: [FolderConfig] {
        folders.values.filter { !$0.removed }.sorted { $0.folderID < $1.folderID }
    }

    var maxLatestSyncRunSeq: Int {
        connected.map { $0.replay.latestSyncRunSeq }.max() ?? 0
    }

    func requireNoConflicts() throws {
        if !conflicts.isEmpty { throw OKDiskError.conflictsBlocked(conflicts) }
    }
}

public final class OKDiskEngine {
    public let configStore: DestinationConfigStore
    public let hostname: String

    public init(configPath: String? = nil, hostname: String = okdiskCurrentHostname(), environment: OKDiskEnvironment = .development) {
        self.configStore = DestinationConfigStore(configPath: configPath, environment: environment)
        self.hostname = hostname.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func getStatus(activeOperationID: String? = nil) -> ServiceStatus {
        do {
            let state = try loadState()
            let statusState = !state.conflicts.isEmpty ? "attention_needed" : "idle"
            let detail: String
            if !state.conflicts.isEmpty {
                detail = "Destination logs require reconciliation"
            } else if state.connected.isEmpty {
                detail = "No online destinations"
            } else {
                detail = "Ready"
            }
            return ServiceStatus(
                state: activeOperationID == nil ? statusState : "operation_running",
                detail: activeOperationID == nil ? detail : "Operation running",
                destinationCount: state.statuses.count,
                onlineDestinationCount: state.connected.count,
                folderCount: state.activeFolders.count,
                activeOperationID: activeOperationID,
                conflicts: state.conflicts
            )
        } catch {
            return ServiceStatus(
                state: "attention_needed",
                detail: error.localizedDescription,
                destinationCount: 0,
                onlineDestinationCount: 0,
                folderCount: 0,
                activeOperationID: activeOperationID,
                conflicts: []
            )
        }
    }

    public func listDestinations() throws -> [DestinationStatus] {
        try loadState().statuses
    }

    public func listFolders(includeRemoved: Bool = false) throws -> [FolderConfig] {
        let folders = try loadState().folders.values.sorted { $0.folderID < $1.folderID }
        return includeRemoved ? folders : folders.filter { !$0.removed }
    }

    public func getStateConflicts() throws -> [DestinationStateConflict] {
        try loadState().conflicts
    }

    public func attachDestination(_ request: AttachDestinationRequest) throws -> DestinationStatus {
        let context = try DestinationStore.initialize(rootPath: request.rootPath, hostname: hostname)
        _ = try configStore.addRoot(context.canonicalRootPath)
        return try loadState().statuses.first { $0.canonicalRootPath == context.canonicalRootPath } ?? context.status
    }

    public func removeDestination(rootPath: String) throws {
        try configStore.removeRoot(rootPath)
    }

    public func addFolder(_ request: AddFolderRequest) throws -> FolderConfig {
        let state = try loadState()
        try state.requireNoConflicts()
        guard !state.connected.isEmpty else { throw OKDiskError.noDestinations }
        guard request.replicaCount > 0 else { throw OKDiskError.insufficientReplicas(required: request.replicaCount, available: state.connected.count) }
        guard state.connected.count >= request.replicaCount else {
            throw OKDiskError.insufficientReplicas(required: request.replicaCount, available: state.connected.count)
        }
        let sourcePath = okdiskCanonicalExistingPath(request.sourcePath)
        guard okdiskIsDirectory(sourcePath) else { throw OKDiskError.sourceUnavailable(request.sourcePath) }
        let folderID = okdiskFolderID(hostname: hostname, sourcePath: sourcePath)
        let folder = FolderConfig(
            folderID: folderID,
            hostname: hostname,
            sourcePath: sourcePath,
            replicaCount: request.replicaCount,
            excludedPatterns: request.excludedPatterns,
            removed: false
        )
        let event = MetadataEvent(
            eventType: MetadataEventType.folderUpsert,
            hostname: folder.hostname,
            sourcePath: folder.sourcePath,
            folderID: folder.folderID,
            replicaCount: folder.replicaCount,
            excludedPatterns: folder.excludedPatterns
        )
        try MetadataLog.append(event, to: state.connected)
        return folder
    }

    public func updateFolder(_ request: UpdateFolderRequest) throws -> FolderConfig {
        let state = try loadState()
        try state.requireNoConflicts()
        guard var folder = state.folders[request.folderID], !folder.removed else { throw OKDiskError.folderNotFound(request.folderID) }
        if let replicaCount = request.replicaCount {
            guard replicaCount > 0, replicaCount <= state.connected.count else {
                throw OKDiskError.insufficientReplicas(required: replicaCount, available: state.connected.count)
            }
            folder.replicaCount = replicaCount
        }
        if let excluded = request.excludedPatterns { folder.excludedPatterns = excluded }
        let event = MetadataEvent(
            eventType: MetadataEventType.folderUpsert,
            hostname: folder.hostname,
            sourcePath: folder.sourcePath,
            folderID: folder.folderID,
            replicaCount: folder.replicaCount,
            excludedPatterns: folder.excludedPatterns
        )
        try MetadataLog.append(event, to: state.connected)
        return folder
    }

    public func removeFolder(folderID: String) throws {
        let state = try loadState()
        try state.requireNoConflicts()
        guard let folder = state.folders[folderID] else { throw OKDiskError.folderNotFound(folderID) }
        let event = MetadataEvent(
            eventType: MetadataEventType.folderRemove,
            hostname: folder.hostname,
            sourcePath: folder.sourcePath,
            folderID: folder.folderID
        )
        try MetadataLog.append(event, to: state.connected)
    }

    public func backup(_ request: BackupRequest = BackupRequest()) throws -> OperationSummary {
        let state = try loadState()
        try state.requireNoConflicts()
        guard !state.connected.isEmpty else { throw OKDiskError.noDestinations }
        let folders = try foldersForMutation(state: state, folderID: request.folderID)
        let fault = FaultController(fault: request.fault)
        var summary = OperationSummary()
        var nextSeq = state.maxLatestSyncRunSeq

        for folder in folders {
            guard okdiskIsDirectory(folder.sourcePath) else { throw OKDiskError.sourceUnavailable(folder.sourcePath) }
            let replicas = try selectedReplicas(for: folder, from: state.connected)
            nextSeq += 1
            let syncRunID = UUID().uuidString
            let start = MetadataEvent(
                eventType: MetadataEventType.syncRunStart,
                syncRunID: syncRunID,
                syncRunSeq: nextSeq,
                hostname: folder.hostname,
                sourcePath: folder.sourcePath,
                folderID: folder.folderID,
                trigger: "manual"
            )
            try MetadataLog.append(start, to: state.connected)
            try fault.afterSyncStart()

            var folderSummary = BackupRunSummary()
            for destination in replicas {
                let mirror = try FileMirror.mirrorSource(
                    sourceRoot: folder.sourcePath,
                    treeRoot: destination.treeRoot(for: folder),
                    tmpRoot: destination.tmpRootPath,
                    syncRunID: syncRunID,
                    excludedPatterns: folder.excludedPatterns,
                    fault: fault
                )
                folderSummary.add(mirror)
            }
            try fault.beforeSyncEnd()
            let end = MetadataEvent(
                eventType: MetadataEventType.syncRunEnd,
                syncRunID: syncRunID,
                syncRunSeq: nextSeq,
                hostname: folder.hostname,
                sourcePath: folder.sourcePath,
                folderID: folder.folderID,
                summary: folderSummary
            )
            try MetadataLog.append(end, to: state.connected)
            summary.addBackup(folderSummary)
        }

        summary.message = "Backup completed"
        return summary
    }

    public func restore(_ request: RestoreRequest) throws -> OperationSummary {
        let state = try loadState()
        try state.requireNoConflicts()
        guard let folder = state.folders[request.folderID], !folder.removed else { throw OKDiskError.folderNotFound(request.folderID) }
        let replicas = try selectedReplicas(for: folder, from: state.connected)
        guard let sourceReplica = replicas.first(where: { okdiskIsDirectory($0.treeRoot(for: folder)) }) else {
            throw OKDiskError.unrecoverable("No readable replica tree for folder \(folder.folderID)")
        }
        let treeRoot = sourceReplica.treeRoot(for: folder)
        let restoreBase = okdiskStandardPath(request.destinationPath)
        try okdiskEnsureDirectory(restoreBase)
        let folderName = URL(fileURLWithPath: folder.sourcePath).lastPathComponent
        var outputRoot = restoreBase + "/\(folderName) - OKDisk Restore \(okdiskFileSafeTimestampUTC())"
        if okdiskPathExists(outputRoot) || lstatExists(outputRoot) {
            guard request.overwriteConfirmed else { throw OKDiskError.restoreCollision(outputRoot) }
            try okdiskRemoveItemIfExists(outputRoot)
        }
        outputRoot = okdiskStandardPath(outputRoot)
        let include: (String, FileNode) -> Bool
        switch request.scope {
        case .fullFolder:
            include = { _, _ in true }
        case .subfolder:
            guard let raw = request.relativePath else { throw OKDiskError.invalidPath("Subfolder restore requires relativePath") }
            let subpath = try okdiskValidateRelativePath(raw)
            include = { rel, _ in rel == subpath || rel.hasPrefix(subpath + "/") }
        case .singleFile:
            guard let raw = request.relativePath else { throw OKDiskError.invalidPath("Single-file restore requires relativePath") }
            let filePath = try okdiskValidateRelativePath(raw)
            include = { rel, node in rel == filePath && node.kind != .directory }
        }
        var result = try FileMirror.copySubset(
            sourceTreeRoot: treeRoot,
            outputRoot: outputRoot,
            include: include,
            overwriteConfirmed: request.overwriteConfirmed
        )
        result.message = "Restore completed"
        return result
    }

    public func verify(_ request: VerifyRequest = VerifyRequest()) throws -> VerifyReport {
        let state = try loadState()
        var report = VerifyReport(deep: request.deep)
        for conflict in state.conflicts {
            report.issues.append(VerificationIssue(kind: "conflict", destinationRoot: conflict.rootPath, message: conflict.message))
        }
        for status in state.statuses where status.state == .offline {
            report.issues.append(VerificationIssue(kind: "offline", destinationRoot: status.rootPath, message: status.message ?? "Destination offline"))
        }
        let folders = try foldersForRead(state: state, folderID: request.folderID)
        report.checkedFolders = folders.count

        for folder in folders {
            let replicas: [DestinationContext]
            do {
                replicas = try selectedReplicas(for: folder, from: state.connected)
            } catch OKDiskError.insufficientReplicas {
                report.issues.append(VerificationIssue(kind: "replica_count", folderID: folder.folderID, message: "Replica count cannot be satisfied"))
                continue
            }
            guard !replicas.isEmpty else {
                report.issues.append(VerificationIssue(kind: "replica_count", folderID: folder.folderID, message: "No online replicas"))
                continue
            }
            if !request.deep {
                for replica in replicas where !okdiskIsDirectory(replica.treeRoot(for: folder)) {
                    report.issues.append(VerificationIssue(kind: "missing_tree", folderID: folder.folderID, destinationRoot: replica.canonicalRootPath, message: "Missing tree mirror"))
                }
                continue
            }

            let expectedRoot: String
            let expected: Snapshot
            if okdiskIsDirectory(folder.sourcePath) {
                expectedRoot = okdiskCanonicalExistingPath(folder.sourcePath)
                expected = try FileMirror.snapshotSource(rootPath: folder.sourcePath, excludedPatterns: folder.excludedPatterns)
            } else if let referenceReplica = replicas.first(where: { okdiskIsDirectory($0.treeRoot(for: folder)) }) {
                expectedRoot = referenceReplica.treeRoot(for: folder)
                expected = try FileMirror.snapshotTree(rootPath: expectedRoot)
            } else {
                report.issues.append(VerificationIssue(kind: "missing_tree", folderID: folder.folderID, message: "No source or replica tree available"))
                continue
            }
            report.checkedFiles += expected.fileCount
            for replica in replicas {
                let actualRoot = replica.treeRoot(for: folder)
                guard okdiskIsDirectory(actualRoot) else {
                    report.issues.append(VerificationIssue(kind: "missing_tree", folderID: folder.folderID, destinationRoot: replica.canonicalRootPath, message: "Missing tree mirror"))
                    continue
                }
                let actual = try FileMirror.snapshotTree(rootPath: actualRoot)
                report.issues += try FileMirror.compare(
                    expectedRoot: expectedRoot,
                    expected: expected,
                    actualRoot: actualRoot,
                    actual: actual,
                    folderID: folder.folderID,
                    destinationRoot: replica.canonicalRootPath
                )
            }
        }
        return report
    }

    public func repair(_ request: RepairRequest) throws -> OperationSummary {
        guard request.confirmed else { throw OKDiskError.repairNotConfirmed }
        let state = try loadState()
        try state.requireNoConflicts()
        let folders = try foldersForMutation(state: state, folderID: request.folderID)
        var summary = OperationSummary(message: "Repair completed")
        var changed = false

        for folder in folders {
            let replicas = try selectedReplicas(for: folder, from: state.connected)
            guard let reference = try chooseRepairReference(folder: folder, replicas: replicas) else {
                throw OKDiskError.unrecoverable("No healthy replica available for \(folder.folderID)")
            }
            let referenceTree = reference.treeRoot(for: folder)
            for target in replicas where target.storeID != reference.storeID {
                let targetTree = target.treeRoot(for: folder)
                let matches = (try? FileMirror.snapshotsMatch(referenceTree, targetTree)) ?? false
                guard !matches else { continue }
                let repaired = try FileMirror.mirrorTree(sourceTreeRoot: referenceTree, targetTreeRoot: targetTree, tmpRoot: target.tmpRootPath)
                summary.filesMirrored += repaired.filesMirrored
                summary.filesDeleted += repaired.filesDeleted
                summary.bytesMirrored += repaired.bytesMirrored
                summary.repairedFiles += repaired.filesMirrored + repaired.filesDeleted
                changed = true
            }
        }

        if changed {
            let event = MetadataEvent(
                eventType: MetadataEventType.stateReconcile,
                approvedByUser: true,
                sourceLatestSyncRunID: state.reference?.replay.latestSyncRunID,
                sourceLatestSyncRunSeq: state.reference?.replay.latestSyncRunSeq,
                updatedStoreIDs: state.connected.map { $0.storeID },
                reason: "repair_from_healthy_replica"
            )
            try MetadataLog.append(event, to: state.connected)
        }
        return summary
    }

    public func confirmUpdateDestinationsToLatest(_ request: ReconcileRequest) throws -> OperationSummary {
        guard request.confirmed else { throw OKDiskError.reconciliationNotConfirmed }
        let state = try loadState()
        guard !state.conflicts.isEmpty else {
            return OperationSummary(message: "No conflicts to reconcile")
        }
        guard let reference = state.reference else {
            throw OKDiskError.unrecoverable("No healthy reference destination available")
        }
        let referenceLog = try Data(contentsOf: URL(fileURLWithPath: reference.metadataLogPath))
        var updatedStoreIDs: [String] = []
        var summary = OperationSummary(message: "Reconciliation completed")

        for target in state.connected where target.storeID != reference.storeID {
            try okdiskAtomicWrite(referenceLog, to: target.metadataLogPath)
            updatedStoreIDs.append(target.storeID)
            summary.reconciledDestinations += 1

            for folder in reference.replay.folders.values where !folder.removed {
                let replicas = try selectedReplicas(for: folder, from: state.connected)
                guard replicas.contains(where: { $0.storeID == target.storeID }) else { continue }
                guard let sourceReplica = replicas.first(where: { $0.storeID != target.storeID && okdiskIsDirectory($0.treeRoot(for: folder)) }) else { continue }
                let mirrored = try FileMirror.mirrorTree(
                    sourceTreeRoot: sourceReplica.treeRoot(for: folder),
                    targetTreeRoot: target.treeRoot(for: folder),
                    tmpRoot: target.tmpRootPath
                )
                summary.filesMirrored += mirrored.filesMirrored
                summary.filesDeleted += mirrored.filesDeleted
                summary.bytesMirrored += mirrored.bytesMirrored
            }
        }

        let reconcile = MetadataEvent(
            eventType: MetadataEventType.stateReconcile,
            approvedByUser: true,
            sourceLatestSyncRunID: reference.replay.latestSyncRunID,
            sourceLatestSyncRunSeq: reference.replay.latestSyncRunSeq,
            updatedStoreIDs: updatedStoreIDs,
            reason: "connected_logs_mismatched"
        )
        try MetadataLog.append(reconcile, to: state.connected)
        return summary
    }

    func loadState() throws -> LoadedState {
        let config = try configStore.read()
        var connected: [DestinationContext] = []
        var statuses: [DestinationStatus] = []
        var corruptedContexts: [DestinationContext] = []

        for root in config.destinationRoots {
            guard okdiskIsDirectory(root) else {
                statuses.append(DestinationStatus(rootPath: root, state: .offline, message: "Destination path is missing or not a directory"))
                continue
            }
            do {
                let context = try DestinationStore.loadExisting(rootPath: root)
                if context.replay.corruptLineCount > 0 {
                    corruptedContexts.append(context)
                }
                connected.append(context)
                statuses.append(context.status)
            } catch {
                statuses.append(DestinationStatus(rootPath: root, canonicalRootPath: okdiskCanonicalExistingPath(root), state: .corrupted, message: error.localizedDescription))
            }
        }

        let valid = connected.filter { $0.replay.corruptLineCount == 0 }
        var reference = valid.sorted(by: referenceSort).last
        var conflicts: [DestinationStateConflict] = []
        var stateByStoreID: [String: DestinationState] = [:]
        var messageByStoreID: [String: String] = [:]

        for context in corruptedContexts {
            stateByStoreID[context.storeID] = .corrupted
            messageByStoreID[context.storeID] = "Destination metadata log has \(context.replay.corruptLineCount) corrupt record(s)"
            conflicts.append(DestinationStateConflict(
                rootPath: context.canonicalRootPath,
                storeID: context.storeID,
                state: .corrupted,
                message: messageByStoreID[context.storeID]!,
                latestSyncRunSeq: context.replay.latestSyncRunSeq,
                referenceStoreID: reference?.storeID
            ))
        }

        if let ref = reference {
            for context in valid {
                if context.storeID == ref.storeID {
                    stateByStoreID[context.storeID] = .healthy
                    continue
                }
                if context.replay.signature == ref.replay.signature {
                    stateByStoreID[context.storeID] = .healthy
                    continue
                }
                let kind: DestinationState = context.replay.latestSyncRunSeq < ref.replay.latestSyncRunSeq || context.replay.events.count < ref.replay.events.count ? .stale : .diverged
                let message = kind == .stale
                    ? "Destination is behind the latest healthy log"
                    : "Destination log diverged from the latest healthy log"
                stateByStoreID[context.storeID] = kind
                messageByStoreID[context.storeID] = message
                conflicts.append(DestinationStateConflict(
                    rootPath: context.canonicalRootPath,
                    storeID: context.storeID,
                    state: kind,
                    message: message,
                    latestSyncRunSeq: context.replay.latestSyncRunSeq,
                    referenceStoreID: ref.storeID
                ))
            }
        } else if !connected.isEmpty {
            for context in connected {
                let message = "No healthy destination log is available"
                stateByStoreID[context.storeID] = .corrupted
                messageByStoreID[context.storeID] = message
                conflicts.append(DestinationStateConflict(
                    rootPath: context.canonicalRootPath,
                    storeID: context.storeID,
                    state: .corrupted,
                    message: message,
                    latestSyncRunSeq: context.replay.latestSyncRunSeq,
                    referenceStoreID: nil
                ))
            }
        }

        for index in statuses.indices {
            guard let storeID = statuses[index].storeID, let state = stateByStoreID[storeID] else { continue }
            statuses[index].state = state
            if let message = messageByStoreID[storeID] { statuses[index].message = message }
        }
        for index in connected.indices {
            let storeID = connected[index].storeID
            if let state = stateByStoreID[storeID] { connected[index].status.state = state }
            if let message = messageByStoreID[storeID] { connected[index].status.message = message }
        }

        if reference == nil, let firstValid = valid.first { reference = firstValid }
        let folders = reference?.replay.folders ?? [:]
        return LoadedState(config: config, connected: connected, statuses: statuses, conflicts: conflicts, reference: reference, folders: folders)
    }

    private func foldersForMutation(state: LoadedState, folderID: String?) throws -> [FolderConfig] {
        let folders = try foldersForRead(state: state, folderID: folderID)
        guard !folders.isEmpty else { throw OKDiskError.folderNotFound(folderID ?? "<all>") }
        return folders
    }

    private func foldersForRead(state: LoadedState, folderID: String?) throws -> [FolderConfig] {
        if let folderID {
            guard let folder = state.folders[folderID], !folder.removed else { throw OKDiskError.folderNotFound(folderID) }
            return [folder]
        }
        return state.activeFolders
    }

    private func selectedReplicas(for folder: FolderConfig, from connected: [DestinationContext]) throws -> [DestinationContext] {
        guard folder.replicaCount > 0 else { throw OKDiskError.insufficientReplicas(required: folder.replicaCount, available: connected.count) }
        guard connected.count >= folder.replicaCount else {
            throw OKDiskError.insufficientReplicas(required: folder.replicaCount, available: connected.count)
        }
        return Array(connected.prefix(folder.replicaCount))
    }

    private func chooseRepairReference(folder: FolderConfig, replicas: [DestinationContext]) throws -> DestinationContext? {
        if okdiskIsDirectory(folder.sourcePath) {
            for replica in replicas where okdiskIsDirectory(replica.treeRoot(for: folder)) {
                if (try? FileMirror.snapshotMatchesSource(treeRoot: replica.treeRoot(for: folder), sourceRoot: folder.sourcePath, excludedPatterns: folder.excludedPatterns)) == true {
                    return replica
                }
            }
        }
        return replicas
            .filter { okdiskIsDirectory($0.treeRoot(for: folder)) }
            .max { lhs, rhs in
                let lhsCount = (try? FileMirror.snapshotTree(rootPath: lhs.treeRoot(for: folder)).nodes.count) ?? 0
                let rhsCount = (try? FileMirror.snapshotTree(rootPath: rhs.treeRoot(for: folder)).nodes.count) ?? 0
                return lhsCount < rhsCount
            }
    }

    private func referenceSort(_ lhs: DestinationContext, _ rhs: DestinationContext) -> Bool {
        if lhs.replay.latestSyncRunSeq != rhs.replay.latestSyncRunSeq {
            return lhs.replay.latestSyncRunSeq < rhs.replay.latestSyncRunSeq
        }
        if lhs.replay.events.count != rhs.replay.events.count {
            return lhs.replay.events.count < rhs.replay.events.count
        }
        return lhs.storeID < rhs.storeID
    }
}

public func okdiskTreeRoot(destinationRoot: String, hostname: String, folderID: String) -> String {
    okdiskCanonicalExistingPath(destinationRoot) + "/data/hosts/\(hostname.lowercased())/\(folderID)/tree"
}
