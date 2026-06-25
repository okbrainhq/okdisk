import AppKit
import Foundation
import OKDiskCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var status = ServiceStatus(
        state: "starting",
        detail: "Starting OKDisk engine",
        destinationCount: 0,
        onlineDestinationCount: 0,
        folderCount: 0,
        conflicts: []
    )
    @Published var destinations: [DestinationStatus] = []
    @Published var folders: [FolderConfig] = []
    @Published var conflicts: [DestinationStateConflict] = []
    @Published var recentOperations: [OperationStatus] = []
    @Published var lastError: String?
    @Published var lastMessage: String?
    @Published var isWorking = false
    @Published var isRefreshing = false
    @Published var workingLabel: String?
    @Published var lastUpdated: Date?

    let environmentName: String

    private let service: OKDiskServiceProtocol
    private let host: EngineHost?
    private var refreshTask: Task<Void, Never>?

    var statusLabel: String {
        if let workingLabel { return workingLabel }
        switch status.state {
        case "idle":
            return conflicts.isEmpty ? "Idle" : "Attention Needed"
        case "operation_running":
            return "Operation Running"
        case "starting":
            return "Starting"
        default:
            return "Attention Needed"
        }
    }

    var detail: String { status.detail }

    var hasWarning: Bool {
        lastError != nil || !conflicts.isEmpty || status.state == "attention_needed" ||
            (status.destinationCount > 0 && status.onlineDestinationCount < status.destinationCount)
    }

    var menuStatusIconName: String {
        if isWorking || status.state == "operation_running" { return "arrow.triangle.2.circlepath" }
        return "externaldrive"
    }

    var iconName: String {
        if isWorking || status.state == "operation_running" { return "arrow.triangle.2.circlepath" }
        if hasWarning { return "externaldrive.badge.exclamationmark" }
        return "externaldrive"
    }

    var canMutate: Bool {
        !isWorking && status.activeOperationID == nil
    }

    var canRunDataOperation: Bool {
        canMutate && conflicts.isEmpty
    }

    var canReconcile: Bool {
        canMutate && !conflicts.isEmpty
    }

    init(service: OKDiskServiceProtocol? = nil, environmentName: String? = nil, startPolling: Bool = true) {
        if let service {
            self.service = service
            self.host = nil
            self.environmentName = environmentName ?? "Preview"
        } else {
            let rawEnvironment = Bundle.main.object(forInfoDictionaryKey: "OKDiskEnvironment") as? String
            let appEnvironment: OKDiskEnvironment = rawEnvironment == "prod" ? .production : .development
            let host = EngineHost(environment: appEnvironment)
            self.host = host
            self.service = host.service
            self.environmentName = rawEnvironment == "prod" ? "Production" : "Development"
            host.startXPCListener()
        }

        if startPolling {
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        host?.stopXPCListener()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let nextStatus = await service.getStatus()
        status = nextStatus
        conflicts = nextStatus.conflicts

        do {
            destinations = try await service.listDestinations()
        } catch {
            destinations = []
            setError(error)
        }

        do {
            folders = try await service.listFolders()
        } catch {
            folders = []
            setError(error)
        }

        lastUpdated = Date()
    }

    func clearNotifications() {
        lastError = nil
        lastMessage = nil
    }

    @discardableResult
    func attachDestination(path: String) async -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Choose a destination folder first."
            return false
        }
        return await runMutation("Attaching destination") {
            _ = try await service.attachDestination(AttachDestinationRequest(rootPath: trimmed))
        }
    }

    @discardableResult
    func removeDestination(_ destination: DestinationStatus) async -> Bool {
        guard confirm(
            title: "Remove Destination?",
            message: "OKDisk will forget this destination path, but it will not delete backup data on disk.\n\n\(destination.rootPath)",
            confirmTitle: "Remove"
        ) else { return false }

        return await runMutation("Removing destination") {
            try await service.removeDestination(rootPath: destination.rootPath)
        }
    }

    @discardableResult
    func pruneDestination(_ destination: DestinationStatus) async -> Bool {
        guard conflicts.isEmpty else {
            lastError = "Resolve destination conflicts before pruning."
            return false
        }
        guard destination.state != .offline else {
            lastError = "Destination must be online before pruning."
            return false
        }
        guard confirm(
            title: "Prune Destination?",
            message: "OKDisk will delete backup tree directories on this destination that are no longer linked to any active source folder replica.\n\nThis cannot be undone.\n\n\(destination.rootPath)",
            confirmTitle: "Prune"
        ) else { return false }

        return await runOperation("Pruning destination") {
            try await service.startPruneDestination(PruneDestinationRequest(destinationRootPath: destination.rootPath, confirmed: true))
        }
    }

    @discardableResult
    func addFolder(path: String, replicaCount: Int, excludedPatterns: [String]) async -> Bool {
        guard conflicts.isEmpty else {
            lastError = "Resolve destination conflicts before changing folders."
            return false
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Choose a source folder first."
            return false
        }
        guard replicaCount > 0 else {
            lastError = "Replica count must be at least 1."
            return false
        }

        return await runMutation("Adding folder") {
            _ = try await service.addFolder(AddFolderRequest(
                sourcePath: trimmed,
                replicaCount: replicaCount,
                excludedPatterns: excludedPatterns
            ))
        }
    }

    @discardableResult
    func updateFolderReplica(folderID: String, replicaCount: Int) async -> Bool {
        guard conflicts.isEmpty else {
            lastError = "Resolve destination conflicts before changing folders."
            return false
        }
        guard replicaCount > 0 else {
            lastError = "Replica count must be at least 1."
            return false
        }
        return await runMutation("Updating folder") {
            _ = try await service.updateFolder(UpdateFolderRequest(folderID: folderID, replicaCount: replicaCount))
        }
    }

    @discardableResult
    func removeFolder(_ folder: FolderConfig) async -> Bool {
        guard conflicts.isEmpty else {
            lastError = "Resolve destination conflicts before changing folders."
            return false
        }
        guard confirm(
            title: "Remove Folder?",
            message: "OKDisk will tombstone this source folder in destination metadata. Backup data is not deleted.\n\n\(folder.sourcePath)",
            confirmTitle: "Remove"
        ) else { return false }

        return await runMutation("Removing folder") {
            try await service.removeFolder(folderID: folder.folderID)
        }
    }

    @discardableResult
    func backupAll() async -> Bool {
        guard conflicts.isEmpty else {
            lastError = "Resolve destination conflicts before running backup."
            return false
        }
        return await runOperation("Backing up") {
            try await service.startBackup(folderID: nil)
        }
    }

    @discardableResult
    func backup(folderID: String) async -> Bool {
        guard conflicts.isEmpty else {
            lastError = "Resolve destination conflicts before running backup."
            return false
        }
        return await runOperation("Backing up folder") {
            try await service.startBackup(folderID: folderID)
        }
    }

    @discardableResult
    func verify(deep: Bool, folderID: String? = nil) async -> Bool {
        await runOperation(deep ? "Deep verification" : "Verification") {
            try await service.startVerification(VerifyRequest(deep: deep, folderID: folderID))
        }
    }

    @discardableResult
    func restore(folderID: String, destinationPath: String, scope: RestoreScope, relativePath: String?, overwriteConfirmed: Bool, deepVerify: Bool) async -> Bool {
        guard conflicts.isEmpty else {
            lastError = "Resolve destination conflicts before restoring."
            return false
        }
        let output = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folderID.isEmpty else {
            lastError = "Choose a folder to restore."
            return false
        }
        guard !output.isEmpty else {
            lastError = "Choose a restore destination folder."
            return false
        }

        let cleanRelative = relativePath?.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
        if scope != .fullFolder, (cleanRelative ?? "").isEmpty {
            lastError = "Enter a relative path for subfolder or single-file restore."
            return false
        }

        return await runOperation("Restoring") {
            try await service.startRestore(RestoreRequest(
                folderID: folderID,
                destinationPath: output,
                scope: scope,
                relativePath: scope == .fullFolder ? nil : cleanRelative,
                overwriteConfirmed: overwriteConfirmed,
                deepVerify: deepVerify
            ))
        }
    }

    @discardableResult
    func reconcileConflicts() async -> Bool {
        guard canReconcile else {
            lastError = conflicts.isEmpty ? "There are no conflicts to reconcile." : "Another operation is running."
            return false
        }
        guard confirm(
            title: "Update Destinations to Latest?",
            message: "This copies the latest destination log to stale/diverged destinations and records an explicit reconciliation event.",
            confirmTitle: "Update"
        ) else { return false }

        return await runOperation("Reconciling destinations") {
            try await service.confirmUpdateDestinationsToLatest(ReconcileRequest(confirmed: true))
        }
    }

    private func runMutation(_ label: String, body: () async throws -> Void) async -> Bool {
        guard canMutate else {
            lastError = "Another OKDisk operation is already running."
            return false
        }
        isWorking = true
        workingLabel = label
        lastError = nil
        lastMessage = "\(label)…"
        defer {
            isWorking = false
            workingLabel = nil
        }

        do {
            try await body()
            lastMessage = "\(label) completed."
            await refresh()
            return true
        } catch {
            setError(error)
            await refresh()
            return false
        }
    }

    private func runOperation(_ label: String, body: () async throws -> String) async -> Bool {
        guard canMutate else {
            lastError = "Another OKDisk operation is already running."
            return false
        }
        isWorking = true
        workingLabel = label
        lastError = nil
        lastMessage = "\(label)…"
        defer {
            isWorking = false
            workingLabel = nil
        }

        do {
            let operationID = try await body()
            if let operation = await service.getOperation(operationID) {
                upsertOperation(operation)
                lastMessage = completionMessage(for: operation)
            } else {
                lastMessage = "\(label) completed."
            }
            await refresh()
            return true
        } catch {
            setError(error)
            await refresh()
            return false
        }
    }

    private func upsertOperation(_ operation: OperationStatus) {
        if let index = recentOperations.firstIndex(where: { $0.id == operation.id }) {
            recentOperations[index] = operation
        } else {
            recentOperations.insert(operation, at: 0)
        }
        if recentOperations.count > 25 {
            recentOperations.removeLast(recentOperations.count - 25)
        }
    }

    private func completionMessage(for operation: OperationStatus) -> String {
        let title = operation.kind.rawValue.capitalized
        if let errorMessage = operation.errorMessage, !errorMessage.isEmpty {
            return "\(title) failed: \(errorMessage)"
        }
        if let message = operation.summary?.message, !message.isEmpty {
            return message
        }
        switch operation.state {
        case .succeeded: return "\(title) completed."
        case .failed: return "\(title) failed."
        case .running: return "\(title) is running."
        }
    }

    private func setError(_ error: Error) {
        lastError = error.localizedDescription
        lastMessage = nil
    }

    private func confirm(title: String, message: String, confirmTitle: String) -> Bool {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum DirectoryPicker {
    @MainActor
    static func pickDirectory(title: String, message: String? = nil, prompt: String = "Choose") -> String? {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message ?? ""
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

enum OKDiskAX {
    static let menuIcon = "okdisk.menu.icon"
    static let menuBackupNow = "okdisk.menu.backupNow"
    static let menuVerify = "okdisk.menu.verify"
    static let menuDashboard = "okdisk.menu.dashboard"
    static let menuDestinations = "okdisk.menu.destinations"
    static let menuFolders = "okdisk.menu.folders"
    static let menuRestore = "okdisk.menu.restore"
    static let menuActivity = "okdisk.menu.activity"
    static let dashboardTabs = "okdisk.dashboard.tabs"
    static let statusLabel = "okdisk.status.label"
    static let statusDetail = "okdisk.status.detail"
    static let refreshButton = "okdisk.refresh"
    static let addDestination = "okdisk.destinations.add"
    static let destinationList = "okdisk.destinations.list"
    static let pruneDestination = "okdisk.destinations.prune"
    static let addFolder = "okdisk.folders.add"
    static let folderList = "okdisk.folders.list"
    static let restoreRun = "okdisk.restore.run"
    static let activityList = "okdisk.activity.list"
    static let reconcileButton = "okdisk.conflicts.reconcile"
}

final class PreviewOKDiskService: OKDiskServiceProtocol {
    private var destinations: [DestinationStatus] = [
        DestinationStatus(
            rootPath: "/tmp/okdisk-preview/dest-a",
            canonicalRootPath: "/tmp/okdisk-preview/dest-a",
            storeID: "preview-store-a",
            state: .healthy,
            isWritable: true,
            latestSyncRunSeq: 3
        ),
        DestinationStatus(
            rootPath: "/tmp/okdisk-preview/dest-b",
            canonicalRootPath: "/tmp/okdisk-preview/dest-b",
            storeID: "preview-store-b",
            state: .healthy,
            isWritable: true,
            latestSyncRunSeq: 3
        )
    ]
    private var folders: [FolderConfig] = [
        FolderConfig(folderID: "preview-documents", hostname: "preview-mac", sourcePath: "/Users/me/Documents", replicaCount: 2)
    ]
    private var operations: [String: OperationStatus] = [:]
    private var conflicts: [DestinationStateConflict] = []

    func getStatus() async -> ServiceStatus {
        ServiceStatus(
            state: conflicts.isEmpty ? "idle" : "attention_needed",
            detail: conflicts.isEmpty ? "Preview ready" : "Preview conflicts need reconciliation",
            destinationCount: destinations.count,
            onlineDestinationCount: destinations.filter { $0.state != .offline }.count,
            folderCount: folders.count,
            conflicts: conflicts
        )
    }

    func listDestinations() async throws -> [DestinationStatus] { destinations }

    func attachDestination(_ request: AttachDestinationRequest) async throws -> DestinationStatus {
        let destination = DestinationStatus(
            rootPath: request.rootPath,
            canonicalRootPath: request.rootPath,
            storeID: UUID().uuidString,
            state: .healthy,
            isWritable: true
        )
        destinations.append(destination)
        return destination
    }

    func removeDestination(rootPath: String) async throws {
        destinations.removeAll { $0.rootPath == rootPath }
    }

    func listFolders() async throws -> [FolderConfig] { folders }

    func addFolder(_ request: AddFolderRequest) async throws -> FolderConfig {
        let folder = FolderConfig(
            folderID: "preview-\(UUID().uuidString.prefix(8))",
            hostname: "preview-mac",
            sourcePath: request.sourcePath,
            replicaCount: request.replicaCount,
            excludedPatterns: request.excludedPatterns
        )
        folders.append(folder)
        return folder
    }

    func updateFolder(_ request: UpdateFolderRequest) async throws -> FolderConfig {
        guard let index = folders.firstIndex(where: { $0.folderID == request.folderID }) else {
            throw OKDiskError.folderNotFound(request.folderID)
        }
        if let replicaCount = request.replicaCount { folders[index].replicaCount = replicaCount }
        if let excludedPatterns = request.excludedPatterns { folders[index].excludedPatterns = excludedPatterns }
        return folders[index]
    }

    func removeFolder(folderID: String) async throws {
        folders.removeAll { $0.folderID == folderID }
    }

    func startBackup(folderID: String?) async throws -> String {
        try await startBackup(BackupRequest(folderID: folderID))
    }

    func startBackup(_ request: BackupRequest) async throws -> String {
        makeOperation(kind: .backup, summary: OperationSummary(filesMirrored: 4, bytesMirrored: 4096, message: "Preview backup completed"))
    }

    func startRestore(_ request: RestoreRequest) async throws -> String {
        makeOperation(kind: .restore, summary: OperationSummary(filesRestored: 2, bytesRestored: 2048, outputPath: request.destinationPath, message: "Preview restore completed"))
    }

    func startVerification(_ request: VerifyRequest) async throws -> String {
        makeOperation(
            kind: .verification,
            summary: OperationSummary(verificationIssues: 0, message: "Preview verification healthy"),
            verifyReport: VerifyReport(deep: request.deep, checkedFolders: folders.count, checkedFiles: 4)
        )
    }

    func startRepair(_ request: RepairRequest) async throws -> String {
        makeOperation(kind: .repair, summary: OperationSummary(repairedFiles: 1, message: "Preview repair completed"))
    }

    func startPruneDestination(_ request: PruneDestinationRequest) async throws -> String {
        makeOperation(kind: .prune, summary: OperationSummary(filesDeleted: 2, prunedTrees: 1, message: "Preview prune completed"))
    }

    func getStateConflicts() async throws -> [DestinationStateConflict] { conflicts }

    func confirmUpdateDestinationsToLatest(_ request: ReconcileRequest) async throws -> String {
        conflicts.removeAll()
        return makeOperation(kind: .reconcile, summary: OperationSummary(reconciledDestinations: 1, message: "Preview reconciliation completed"))
    }

    func cancelOperation(_ operationID: String) async throws {}

    func getOperation(_ operationID: String) async -> OperationStatus? {
        operations[operationID]
    }

    private func makeOperation(kind: OperationKind, summary: OperationSummary? = nil, verifyReport: VerifyReport? = nil) -> String {
        let id = UUID().uuidString
        operations[id] = OperationStatus(
            id: id,
            kind: kind,
            state: .succeeded,
            startedAtUTC: nowUTC(),
            completedAtUTC: nowUTC(),
            summary: summary,
            verifyReport: verifyReport
        )
        return id
    }

    private func nowUTC() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
