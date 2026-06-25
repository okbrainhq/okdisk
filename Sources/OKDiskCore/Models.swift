import Foundation

public enum OKDiskEnvironment: String, Codable, Sendable {
    case development
    case production
    case test
}

public enum DestinationState: String, Codable, Sendable {
    case healthy
    case offline
    case stale
    case diverged
    case corrupted
}

public enum OperationState: String, Codable, Sendable {
    case running
    case succeeded
    case failed
}

public enum OperationKind: String, Codable, Sendable {
    case backup
    case restore
    case verification
    case repair
    case reconcile
}

public enum RestoreScope: String, Codable, Sendable {
    case fullFolder
    case subfolder
    case singleFile
}

public struct AttachDestinationRequest: Codable, Equatable, Sendable {
    public var rootPath: String

    public init(rootPath: String) {
        self.rootPath = rootPath
    }
}

public struct AddFolderRequest: Codable, Equatable, Sendable {
    public var sourcePath: String
    public var replicaCount: Int
    public var excludedPatterns: [String]

    public init(sourcePath: String, replicaCount: Int, excludedPatterns: [String] = [".DS_Store", ".okdisk/**"]) {
        self.sourcePath = sourcePath
        self.replicaCount = replicaCount
        self.excludedPatterns = excludedPatterns
    }
}

public struct UpdateFolderRequest: Codable, Equatable, Sendable {
    public var folderID: String
    public var replicaCount: Int?
    public var excludedPatterns: [String]?

    public init(folderID: String, replicaCount: Int? = nil, excludedPatterns: [String]? = nil) {
        self.folderID = folderID
        self.replicaCount = replicaCount
        self.excludedPatterns = excludedPatterns
    }
}

public struct BackupFault: Codable, Equatable, Sendable {
    public var mode: String
    public var payloadWriteLimit: Int?

    public init(mode: String, payloadWriteLimit: Int? = nil) {
        self.mode = mode
        self.payloadWriteLimit = payloadWriteLimit
    }

    public static let afterSyncStart = BackupFault(mode: "after-sync-start")
    public static let beforeSyncEnd = BackupFault(mode: "before-sync-end")

    public static func afterPayloadWrites(_ limit: Int) -> BackupFault {
        BackupFault(mode: "after-payload-writes", payloadWriteLimit: limit)
    }
}

public struct BackupRequest: Codable, Equatable, Sendable {
    public var folderID: String?
    public var fault: BackupFault?

    public init(folderID: String? = nil, fault: BackupFault? = nil) {
        self.folderID = folderID
        self.fault = fault
    }
}

public struct RestoreRequest: Codable, Equatable, Sendable {
    public var folderID: String
    public var destinationPath: String
    public var scope: RestoreScope
    public var relativePath: String?
    public var overwriteConfirmed: Bool
    public var deepVerify: Bool

    public init(
        folderID: String,
        destinationPath: String,
        scope: RestoreScope = .fullFolder,
        relativePath: String? = nil,
        overwriteConfirmed: Bool = false,
        deepVerify: Bool = false
    ) {
        self.folderID = folderID
        self.destinationPath = destinationPath
        self.scope = scope
        self.relativePath = relativePath
        self.overwriteConfirmed = overwriteConfirmed
        self.deepVerify = deepVerify
    }
}

public struct VerifyRequest: Codable, Equatable, Sendable {
    public var deep: Bool
    public var folderID: String?

    public init(deep: Bool = false, folderID: String? = nil) {
        self.deep = deep
        self.folderID = folderID
    }
}

public struct RepairRequest: Codable, Equatable, Sendable {
    public var folderID: String?
    public var confirmed: Bool

    public init(folderID: String? = nil, confirmed: Bool = false) {
        self.folderID = folderID
        self.confirmed = confirmed
    }
}

public struct ReconcileRequest: Codable, Equatable, Sendable {
    public var confirmed: Bool

    public init(confirmed: Bool) {
        self.confirmed = confirmed
    }
}

public struct FolderConfig: Codable, Equatable, Sendable {
    public var folderID: String
    public var hostname: String
    public var sourcePath: String
    public var replicaCount: Int
    public var replicaStoreIDs: [String]?
    public var excludedPatterns: [String]
    public var removed: Bool

    enum CodingKeys: String, CodingKey {
        case folderID = "folder_id"
        case hostname
        case sourcePath = "source_path"
        case replicaCount = "replica_count"
        case replicaStoreIDs = "replica_store_ids"
        case excludedPatterns = "excluded_patterns"
        case removed
    }

    public init(
        folderID: String,
        hostname: String,
        sourcePath: String,
        replicaCount: Int,
        replicaStoreIDs: [String]? = nil,
        excludedPatterns: [String] = [".DS_Store", ".okdisk/**"],
        removed: Bool = false
    ) {
        self.folderID = folderID
        self.hostname = hostname
        self.sourcePath = sourcePath
        self.replicaCount = replicaCount
        self.replicaStoreIDs = replicaStoreIDs
        self.excludedPatterns = excludedPatterns
        self.removed = removed
    }
}

public struct DestinationStatus: Codable, Equatable, Sendable {
    public var rootPath: String
    public var canonicalRootPath: String?
    public var storeID: String?
    public var state: DestinationState
    public var isWritable: Bool
    public var latestSyncRunSeq: Int
    public var skippedCorruptRecords: Int
    public var skippedPartialRecord: Bool
    public var message: String?

    enum CodingKeys: String, CodingKey {
        case rootPath = "root_path"
        case canonicalRootPath = "canonical_root_path"
        case storeID = "store_id"
        case state
        case isWritable = "is_writable"
        case latestSyncRunSeq = "latest_sync_run_seq"
        case skippedCorruptRecords = "skipped_corrupt_records"
        case skippedPartialRecord = "skipped_partial_record"
        case message
    }

    public init(
        rootPath: String,
        canonicalRootPath: String? = nil,
        storeID: String? = nil,
        state: DestinationState,
        isWritable: Bool = false,
        latestSyncRunSeq: Int = 0,
        skippedCorruptRecords: Int = 0,
        skippedPartialRecord: Bool = false,
        message: String? = nil
    ) {
        self.rootPath = rootPath
        self.canonicalRootPath = canonicalRootPath
        self.storeID = storeID
        self.state = state
        self.isWritable = isWritable
        self.latestSyncRunSeq = latestSyncRunSeq
        self.skippedCorruptRecords = skippedCorruptRecords
        self.skippedPartialRecord = skippedPartialRecord
        self.message = message
    }
}

public struct DestinationStateConflict: Codable, Equatable, Sendable {
    public var rootPath: String
    public var storeID: String?
    public var state: DestinationState
    public var message: String
    public var latestSyncRunSeq: Int
    public var referenceStoreID: String?

    enum CodingKeys: String, CodingKey {
        case rootPath = "root_path"
        case storeID = "store_id"
        case state
        case message
        case latestSyncRunSeq = "latest_sync_run_seq"
        case referenceStoreID = "reference_store_id"
    }

    public init(
        rootPath: String,
        storeID: String?,
        state: DestinationState,
        message: String,
        latestSyncRunSeq: Int,
        referenceStoreID: String?
    ) {
        self.rootPath = rootPath
        self.storeID = storeID
        self.state = state
        self.message = message
        self.latestSyncRunSeq = latestSyncRunSeq
        self.referenceStoreID = referenceStoreID
    }
}

public struct ServiceStatus: Codable, Equatable, Sendable {
    public var state: String
    public var detail: String
    public var destinationCount: Int
    public var onlineDestinationCount: Int
    public var folderCount: Int
    public var activeOperationID: String?
    public var conflicts: [DestinationStateConflict]

    enum CodingKeys: String, CodingKey {
        case state
        case detail
        case destinationCount = "destination_count"
        case onlineDestinationCount = "online_destination_count"
        case folderCount = "folder_count"
        case activeOperationID = "active_operation_id"
        case conflicts
    }

    public init(
        state: String,
        detail: String,
        destinationCount: Int,
        onlineDestinationCount: Int,
        folderCount: Int,
        activeOperationID: String? = nil,
        conflicts: [DestinationStateConflict] = []
    ) {
        self.state = state
        self.detail = detail
        self.destinationCount = destinationCount
        self.onlineDestinationCount = onlineDestinationCount
        self.folderCount = folderCount
        self.activeOperationID = activeOperationID
        self.conflicts = conflicts
    }
}

public struct BackupRunSummary: Codable, Equatable, Sendable {
    public var filesMirrored: Int
    public var filesDeleted: Int
    public var bytesMirrored: Int64
    public var errors: Int

    enum CodingKeys: String, CodingKey {
        case filesMirrored = "files_mirrored"
        case filesDeleted = "files_deleted"
        case bytesMirrored = "bytes_mirrored"
        case errors
    }

    public init(filesMirrored: Int = 0, filesDeleted: Int = 0, bytesMirrored: Int64 = 0, errors: Int = 0) {
        self.filesMirrored = filesMirrored
        self.filesDeleted = filesDeleted
        self.bytesMirrored = bytesMirrored
        self.errors = errors
    }

    mutating func add(_ other: BackupRunSummary) {
        filesMirrored += other.filesMirrored
        filesDeleted += other.filesDeleted
        bytesMirrored += other.bytesMirrored
        errors += other.errors
    }
}

public struct VerificationIssue: Codable, Equatable, Sendable {
    public var kind: String
    public var severity: String
    public var folderID: String?
    public var relativePath: String?
    public var destinationRoot: String?
    public var message: String

    enum CodingKeys: String, CodingKey {
        case kind
        case severity
        case folderID = "folder_id"
        case relativePath = "relative_path"
        case destinationRoot = "destination_root"
        case message
    }

    public init(kind: String, severity: String = "error", folderID: String? = nil, relativePath: String? = nil, destinationRoot: String? = nil, message: String) {
        self.kind = kind
        self.severity = severity
        self.folderID = folderID
        self.relativePath = relativePath
        self.destinationRoot = destinationRoot
        self.message = message
    }
}

public struct VerifyReport: Codable, Equatable, Sendable {
    public var deep: Bool
    public var checkedFolders: Int
    public var checkedFiles: Int
    public var issues: [VerificationIssue]

    enum CodingKeys: String, CodingKey {
        case deep
        case checkedFolders = "checked_folders"
        case checkedFiles = "checked_files"
        case issues
    }

    public var isHealthy: Bool { issues.isEmpty }

    public init(deep: Bool, checkedFolders: Int = 0, checkedFiles: Int = 0, issues: [VerificationIssue] = []) {
        self.deep = deep
        self.checkedFolders = checkedFolders
        self.checkedFiles = checkedFiles
        self.issues = issues
    }
}

public struct OperationSummary: Codable, Equatable, Sendable {
    public var filesMirrored: Int
    public var filesDeleted: Int
    public var bytesMirrored: Int64
    public var filesRestored: Int
    public var bytesRestored: Int64
    public var verificationIssues: Int
    public var repairedFiles: Int
    public var reconciledDestinations: Int
    public var outputPath: String?
    public var message: String?

    enum CodingKeys: String, CodingKey {
        case filesMirrored = "files_mirrored"
        case filesDeleted = "files_deleted"
        case bytesMirrored = "bytes_mirrored"
        case filesRestored = "files_restored"
        case bytesRestored = "bytes_restored"
        case verificationIssues = "verification_issues"
        case repairedFiles = "repaired_files"
        case reconciledDestinations = "reconciled_destinations"
        case outputPath = "output_path"
        case message
    }

    public init(
        filesMirrored: Int = 0,
        filesDeleted: Int = 0,
        bytesMirrored: Int64 = 0,
        filesRestored: Int = 0,
        bytesRestored: Int64 = 0,
        verificationIssues: Int = 0,
        repairedFiles: Int = 0,
        reconciledDestinations: Int = 0,
        outputPath: String? = nil,
        message: String? = nil
    ) {
        self.filesMirrored = filesMirrored
        self.filesDeleted = filesDeleted
        self.bytesMirrored = bytesMirrored
        self.filesRestored = filesRestored
        self.bytesRestored = bytesRestored
        self.verificationIssues = verificationIssues
        self.repairedFiles = repairedFiles
        self.reconciledDestinations = reconciledDestinations
        self.outputPath = outputPath
        self.message = message
    }

    mutating func addBackup(_ backup: BackupRunSummary) {
        filesMirrored += backup.filesMirrored
        filesDeleted += backup.filesDeleted
        bytesMirrored += backup.bytesMirrored
    }
}

public struct OperationStatus: Codable, Equatable, Sendable {
    public var id: String
    public var kind: OperationKind
    public var state: OperationState
    public var startedAtUTC: String
    public var completedAtUTC: String?
    public var summary: OperationSummary?
    public var verifyReport: VerifyReport?
    public var errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case state
        case startedAtUTC = "started_at_utc"
        case completedAtUTC = "completed_at_utc"
        case summary
        case verifyReport = "verify_report"
        case errorMessage = "error_message"
    }

    public init(
        id: String,
        kind: OperationKind,
        state: OperationState,
        startedAtUTC: String,
        completedAtUTC: String? = nil,
        summary: OperationSummary? = nil,
        verifyReport: VerifyReport? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.startedAtUTC = startedAtUTC
        self.completedAtUTC = completedAtUTC
        self.summary = summary
        self.verifyReport = verifyReport
        self.errorMessage = errorMessage
    }
}

public enum OKDiskError: Error, CustomStringConvertible, LocalizedError {
    case invalidConfig(String)
    case invalidPath(String)
    case duplicateDestination(String)
    case destinationUnavailable(String)
    case destinationCorrupted(String)
    case noDestinations
    case insufficientReplicas(required: Int, available: Int)
    case conflictsBlocked([DestinationStateConflict])
    case folderNotFound(String)
    case sourceUnavailable(String)
    case restoreCollision(String)
    case overwriteNotConfirmed(String)
    case operationBusy(String)
    case faultInjected(String)
    case reconciliationNotConfirmed
    case repairNotConfirmed
    case unrecoverable(String)

    public var description: String {
        switch self {
        case .invalidConfig(let message): return "Invalid config: \(message)"
        case .invalidPath(let message): return "Invalid path: \(message)"
        case .duplicateDestination(let path): return "Destination already attached: \(path)"
        case .destinationUnavailable(let path): return "Destination unavailable: \(path)"
        case .destinationCorrupted(let message): return "Destination corrupted: \(message)"
        case .noDestinations: return "No destinations attached"
        case .insufficientReplicas(let required, let available): return "Insufficient replicas: required \(required), available \(available)"
        case .conflictsBlocked(let conflicts): return "Destination conflicts block this operation: \(conflicts.map { $0.message }.joined(separator: "; "))"
        case .folderNotFound(let id): return "Folder not found: \(id)"
        case .sourceUnavailable(let path): return "Source unavailable: \(path)"
        case .restoreCollision(let path): return "Restore collision: \(path)"
        case .overwriteNotConfirmed(let path): return "Overwrite not confirmed: \(path)"
        case .operationBusy(let id): return "Operation already running: \(id)"
        case .faultInjected(let message): return "Fault injected: \(message)"
        case .reconciliationNotConfirmed: return "Reconciliation requires explicit confirmation"
        case .repairNotConfirmed: return "Repair requires explicit confirmation"
        case .unrecoverable(let message): return "Unrecoverable: \(message)"
        }
    }

    public var errorDescription: String? { description }
}
