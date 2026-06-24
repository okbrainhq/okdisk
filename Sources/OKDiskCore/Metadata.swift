import Foundation

public enum MetadataEventType {
    public static let folderUpsert = "folder.upsert"
    public static let folderRemove = "folder.remove"
    public static let syncRunStart = "sync_run.start"
    public static let syncRunEnd = "sync_run.end"
    public static let stateReconcile = "state.reconcile"
}

public struct MetadataEvent: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var eventID: String
    public var eventType: String
    public var emittedAtUTC: String
    public var syncRunID: String?
    public var syncRunSeq: Int?
    public var hostname: String?
    public var sourcePath: String?
    public var folderID: String?
    public var replicaCount: Int?
    public var excludedPatterns: [String]?
    public var trigger: String?
    public var summary: BackupRunSummary?
    public var approvedByUser: Bool?
    public var sourceLatestSyncRunID: String?
    public var sourceLatestSyncRunSeq: Int?
    public var updatedStoreIDs: [String]?
    public var reason: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case eventID = "event_id"
        case eventType = "event_type"
        case emittedAtUTC = "emitted_at_utc"
        case syncRunID = "sync_run_id"
        case syncRunSeq = "sync_run_seq"
        case hostname
        case sourcePath = "source_path"
        case folderID = "folder_id"
        case replicaCount = "replica_count"
        case excludedPatterns = "excluded_patterns"
        case trigger
        case summary
        case approvedByUser = "approved_by_user"
        case sourceLatestSyncRunID = "source_latest_sync_run_id"
        case sourceLatestSyncRunSeq = "source_latest_sync_run_seq"
        case updatedStoreIDs = "updated_store_ids"
        case reason
    }

    public init(
        eventType: String,
        eventID: String = UUID().uuidString,
        emittedAtUTC: String = okdiskNowUTC(),
        syncRunID: String? = nil,
        syncRunSeq: Int? = nil,
        hostname: String? = nil,
        sourcePath: String? = nil,
        folderID: String? = nil,
        replicaCount: Int? = nil,
        excludedPatterns: [String]? = nil,
        trigger: String? = nil,
        summary: BackupRunSummary? = nil,
        approvedByUser: Bool? = nil,
        sourceLatestSyncRunID: String? = nil,
        sourceLatestSyncRunSeq: Int? = nil,
        updatedStoreIDs: [String]? = nil,
        reason: String? = nil
    ) {
        self.schemaVersion = 1
        self.eventID = eventID
        self.eventType = eventType
        self.emittedAtUTC = emittedAtUTC
        self.syncRunID = syncRunID
        self.syncRunSeq = syncRunSeq
        self.hostname = hostname
        self.sourcePath = sourcePath
        self.folderID = folderID
        self.replicaCount = replicaCount
        self.excludedPatterns = excludedPatterns
        self.trigger = trigger
        self.summary = summary
        self.approvedByUser = approvedByUser
        self.sourceLatestSyncRunID = sourceLatestSyncRunID
        self.sourceLatestSyncRunSeq = sourceLatestSyncRunSeq
        self.updatedStoreIDs = updatedStoreIDs
        self.reason = reason
    }
}

struct SyncRunRecord: Codable, Equatable {
    var syncRunID: String
    var syncRunSeq: Int
    var folderID: String
    var emittedAtUTC: String
    var summary: BackupRunSummary
}

struct ReplayResult: Equatable {
    var events: [MetadataEvent]
    var folders: [String: FolderConfig]
    var completedRuns: [SyncRunRecord]
    var latestSyncRunSeq: Int
    var latestSyncRunID: String?
    var latestSyncRunEmittedAtUTC: String?
    var reconcileEventIDs: [String]
    var corruptLineCount: Int
    var partialLastLineSkipped: Bool
    var signature: String

    static let empty = ReplayResult(
        events: [],
        folders: [:],
        completedRuns: [],
        latestSyncRunSeq: 0,
        latestSyncRunID: nil,
        latestSyncRunEmittedAtUTC: nil,
        reconcileEventIDs: [],
        corruptLineCount: 0,
        partialLastLineSkipped: false,
        signature: "empty"
    )
}

enum MetadataLog {
    static func append(_ event: MetadataEvent, to destinations: [DestinationContext]) throws {
        let encoded = try okdiskJSONEncoder().encode(event) + Data("\n".utf8)
        for destination in destinations {
            try okdiskAppendLine(encoded, to: destination.metadataLogPath)
        }
    }

    static func replay(path: String) throws -> ReplayResult {
        guard FileManager.default.fileExists(atPath: path) else {
            throw OKDiskError.destinationCorrupted("Missing metadata log at \(path)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard !data.isEmpty else { return .empty }
        let text = String(decoding: data, as: UTF8.self)
        let endedWithNewline = text.hasSuffix("\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var events: [MetadataEvent] = []
        var corrupt = 0
        var partialSkipped = false
        let decoder = okdiskJSONDecoder()

        for (index, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            if line.isEmpty { continue }
            do {
                let event = try decoder.decode(MetadataEvent.self, from: Data(line.utf8))
                guard event.schemaVersion == 1, !event.eventID.isEmpty, !event.eventType.isEmpty else {
                    throw OKDiskError.destinationCorrupted("Invalid event schema")
                }
                events.append(event)
            } catch {
                if index == lines.count - 1 && !endedWithNewline {
                    partialSkipped = true
                } else {
                    corrupt += 1
                }
            }
        }

        return buildReplay(events: events, corruptLineCount: corrupt, partialLastLineSkipped: partialSkipped)
    }

    static func buildReplay(events: [MetadataEvent], corruptLineCount: Int = 0, partialLastLineSkipped: Bool = false) -> ReplayResult {
        var folders: [String: FolderConfig] = [:]
        var completedRuns: [SyncRunRecord] = []
        var reconcileIDs: [String] = []

        for event in events {
            switch event.eventType {
            case MetadataEventType.folderUpsert:
                guard let folderID = event.folderID,
                      let hostname = event.hostname,
                      let sourcePath = event.sourcePath,
                      let replicaCount = event.replicaCount else { continue }
                folders[folderID] = FolderConfig(
                    folderID: folderID,
                    hostname: hostname,
                    sourcePath: sourcePath,
                    replicaCount: replicaCount,
                    excludedPatterns: event.excludedPatterns ?? [".DS_Store", ".okdisk/**"],
                    removed: false
                )
            case MetadataEventType.folderRemove:
                guard let folderID = event.folderID else { continue }
                if var folder = folders[folderID] {
                    folder.removed = true
                    folders[folderID] = folder
                } else {
                    folders[folderID] = FolderConfig(
                        folderID: folderID,
                        hostname: event.hostname ?? "unknown",
                        sourcePath: event.sourcePath ?? "",
                        replicaCount: 1,
                        removed: true
                    )
                }
            case MetadataEventType.syncRunEnd:
                guard let syncRunID = event.syncRunID,
                      let syncRunSeq = event.syncRunSeq,
                      let folderID = event.folderID else { continue }
                completedRuns.append(SyncRunRecord(
                    syncRunID: syncRunID,
                    syncRunSeq: syncRunSeq,
                    folderID: folderID,
                    emittedAtUTC: event.emittedAtUTC,
                    summary: event.summary ?? BackupRunSummary()
                ))
            case MetadataEventType.stateReconcile:
                reconcileIDs.append(event.eventID)
            default:
                continue
            }
        }

        completedRuns.sort { lhs, rhs in
            if lhs.syncRunSeq == rhs.syncRunSeq { return lhs.syncRunID < rhs.syncRunID }
            return lhs.syncRunSeq < rhs.syncRunSeq
        }
        let latest = completedRuns.last
        reconcileIDs.sort()
        let signature = makeSignature(folders: folders, latest: latest, reconcileEventIDs: reconcileIDs)
        return ReplayResult(
            events: events,
            folders: folders,
            completedRuns: completedRuns,
            latestSyncRunSeq: latest?.syncRunSeq ?? 0,
            latestSyncRunID: latest?.syncRunID,
            latestSyncRunEmittedAtUTC: latest?.emittedAtUTC,
            reconcileEventIDs: reconcileIDs,
            corruptLineCount: corruptLineCount,
            partialLastLineSkipped: partialLastLineSkipped,
            signature: signature
        )
    }

    private static func makeSignature(folders: [String: FolderConfig], latest: SyncRunRecord?, reconcileEventIDs: [String]) -> String {
        struct Signature: Codable {
            var folders: [FolderConfig]
            var latestSyncRunID: String?
            var latestSyncRunSeq: Int
            var reconcileEventIDs: [String]
        }
        let signature = Signature(
            folders: folders.values.sorted { $0.folderID < $1.folderID },
            latestSyncRunID: latest?.syncRunID,
            latestSyncRunSeq: latest?.syncRunSeq ?? 0,
            reconcileEventIDs: reconcileEventIDs.sorted()
        )
        let data = (try? okdiskJSONEncoder().encode(signature)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

extension Data {
    static func + (lhs: Data, rhs: Data) -> Data {
        var data = lhs
        data.append(rhs)
        return data
    }
}
