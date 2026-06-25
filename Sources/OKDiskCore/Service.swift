import Foundation

public protocol OKDiskServiceProtocol: AnyObject {
    func getStatus() async -> ServiceStatus
    func listDestinations() async throws -> [DestinationStatus]
    func attachDestination(_ request: AttachDestinationRequest) async throws -> DestinationStatus
    func removeDestination(rootPath: String) async throws

    func listFolders() async throws -> [FolderConfig]
    func addFolder(_ request: AddFolderRequest) async throws -> FolderConfig
    func updateFolder(_ request: UpdateFolderRequest) async throws -> FolderConfig
    func removeFolder(folderID: String) async throws

    func startBackup(folderID: String?) async throws -> String
    func startBackup(_ request: BackupRequest) async throws -> String
    func startRestore(_ request: RestoreRequest) async throws -> String
    func startVerification(_ request: VerifyRequest) async throws -> String
    func startRepair(_ request: RepairRequest) async throws -> String
    func startPruneDestination(_ request: PruneDestinationRequest) async throws -> String
    func getStateConflicts() async throws -> [DestinationStateConflict]
    func confirmUpdateDestinationsToLatest(_ request: ReconcileRequest) async throws -> String
    func cancelOperation(_ operationID: String) async throws
    func getOperation(_ operationID: String) async -> OperationStatus?
}

struct OperationPayload {
    var summary: OperationSummary?
    var verifyReport: VerifyReport?
}

public actor OperationCoordinator {
    private let engine: OKDiskEngine
    private var operations: [String: OperationStatus] = [:]
    private var activeOperationID: String?

    public init(engine: OKDiskEngine) {
        self.engine = engine
    }

    public func getStatus() -> ServiceStatus {
        engine.getStatus(activeOperationID: activeOperationID)
    }

    public func listDestinations() throws -> [DestinationStatus] {
        try engine.listDestinations()
    }

    public func attachDestination(_ request: AttachDestinationRequest) throws -> DestinationStatus {
        try ensureNoActiveOperation()
        return try engine.attachDestination(request)
    }

    public func removeDestination(rootPath: String) throws {
        try ensureNoActiveOperation()
        try engine.removeDestination(rootPath: rootPath)
    }

    public func listFolders() throws -> [FolderConfig] {
        try engine.listFolders()
    }

    public func addFolder(_ request: AddFolderRequest) throws -> FolderConfig {
        try ensureNoActiveOperation()
        return try engine.addFolder(request)
    }

    public func updateFolder(_ request: UpdateFolderRequest) throws -> FolderConfig {
        try ensureNoActiveOperation()
        return try engine.updateFolder(request)
    }

    public func removeFolder(folderID: String) throws {
        try ensureNoActiveOperation()
        try engine.removeFolder(folderID: folderID)
    }

    public func getStateConflicts() throws -> [DestinationStateConflict] {
        try engine.getStateConflicts()
    }

    func runOperation(kind: OperationKind, _ body: () throws -> OperationPayload) throws -> String {
        try ensureNoActiveOperation()
        let id = UUID().uuidString
        activeOperationID = id
        operations[id] = OperationStatus(id: id, kind: kind, state: .running, startedAtUTC: okdiskNowUTC())
        do {
            let payload = try body()
            operations[id]?.state = .succeeded
            operations[id]?.completedAtUTC = okdiskNowUTC()
            operations[id]?.summary = payload.summary
            operations[id]?.verifyReport = payload.verifyReport
            activeOperationID = nil
            return id
        } catch {
            operations[id]?.state = .failed
            operations[id]?.completedAtUTC = okdiskNowUTC()
            operations[id]?.errorMessage = error.localizedDescription
            activeOperationID = nil
            throw error
        }
    }

    public func cancelOperation(_ operationID: String) throws {
        guard activeOperationID == operationID else { return }
        throw OKDiskError.unrecoverable("Cancellation is cooperative and no cancellable operation is currently suspended")
    }

    public func getOperation(_ operationID: String) -> OperationStatus? {
        operations[operationID]
    }

    private func ensureNoActiveOperation() throws {
        if let activeOperationID { throw OKDiskError.operationBusy(activeOperationID) }
    }
}

public final class OKDiskService: OKDiskServiceProtocol {
    public let engine: OKDiskEngine
    public let coordinator: OperationCoordinator

    public init(configPath: String? = nil, hostname: String = okdiskCurrentHostname(), environment: OKDiskEnvironment = .development) {
        let engine = OKDiskEngine(configPath: configPath, hostname: hostname, environment: environment)
        self.engine = engine
        self.coordinator = OperationCoordinator(engine: engine)
    }

    public func getStatus() async -> ServiceStatus {
        await coordinator.getStatus()
    }

    public func listDestinations() async throws -> [DestinationStatus] {
        try await coordinator.listDestinations()
    }

    public func attachDestination(_ request: AttachDestinationRequest) async throws -> DestinationStatus {
        try await coordinator.attachDestination(request)
    }

    public func removeDestination(rootPath: String) async throws {
        try await coordinator.removeDestination(rootPath: rootPath)
    }

    public func listFolders() async throws -> [FolderConfig] {
        try await coordinator.listFolders()
    }

    public func addFolder(_ request: AddFolderRequest) async throws -> FolderConfig {
        try await coordinator.addFolder(request)
    }

    public func updateFolder(_ request: UpdateFolderRequest) async throws -> FolderConfig {
        try await coordinator.updateFolder(request)
    }

    public func removeFolder(folderID: String) async throws {
        try await coordinator.removeFolder(folderID: folderID)
    }

    public func startBackup(folderID: String? = nil) async throws -> String {
        try await startBackup(BackupRequest(folderID: folderID))
    }

    public func startBackup(_ request: BackupRequest) async throws -> String {
        try await coordinator.runOperation(kind: .backup) {
            OperationPayload(summary: try engine.backup(request), verifyReport: nil)
        }
    }

    public func startRestore(_ request: RestoreRequest) async throws -> String {
        try await coordinator.runOperation(kind: .restore) {
            OperationPayload(summary: try engine.restore(request), verifyReport: nil)
        }
    }

    public func startVerification(_ request: VerifyRequest) async throws -> String {
        try await coordinator.runOperation(kind: .verification) {
            let report = try engine.verify(request)
            return OperationPayload(
                summary: OperationSummary(verificationIssues: report.issues.count, message: report.isHealthy ? "Verification healthy" : "Verification found issues"),
                verifyReport: report
            )
        }
    }

    public func startRepair(_ request: RepairRequest) async throws -> String {
        try await coordinator.runOperation(kind: .repair) {
            OperationPayload(summary: try engine.repair(request), verifyReport: nil)
        }
    }

    public func startPruneDestination(_ request: PruneDestinationRequest) async throws -> String {
        try await coordinator.runOperation(kind: .prune) {
            OperationPayload(summary: try engine.pruneDestination(request), verifyReport: nil)
        }
    }

    public func getStateConflicts() async throws -> [DestinationStateConflict] {
        try await coordinator.getStateConflicts()
    }

    public func confirmUpdateDestinationsToLatest(_ request: ReconcileRequest) async throws -> String {
        try await coordinator.runOperation(kind: .reconcile) {
            OperationPayload(summary: try engine.confirmUpdateDestinationsToLatest(request), verifyReport: nil)
        }
    }

    public func cancelOperation(_ operationID: String) async throws {
        try await coordinator.cancelOperation(operationID)
    }

    public func getOperation(_ operationID: String) async -> OperationStatus? {
        await coordinator.getOperation(operationID)
    }
}
