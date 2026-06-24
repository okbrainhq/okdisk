import Foundation

struct DestinationConfig: Codable, Equatable {
    var schemaVersion: Int
    var destinationRoots: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case destinationRoots = "destination_roots"
    }

    init(schemaVersion: Int = 1, destinationRoots: [String] = []) {
        self.schemaVersion = schemaVersion
        self.destinationRoots = destinationRoots
    }
}

public final class DestinationConfigStore {
    public let configPath: String

    public init(configPath: String? = nil, environment: OKDiskEnvironment = .development) {
        if let configPath {
            self.configPath = okdiskStandardPath(configPath)
        } else if let override = ProcessInfo.processInfo.environment["OKDISK_DESTINATIONS_CONFIG"], !override.isEmpty {
            self.configPath = okdiskStandardPath(override)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            switch environment {
            case .production:
                self.configPath = home + "/Library/Application Support/OKDisk/destinations.json"
            case .development:
                self.configPath = home + "/Library/Application Support/OKDisk-Dev/destinations.json"
            case .test:
                self.configPath = FileManager.default.temporaryDirectory.appendingPathComponent("okdisk-test-\(UUID().uuidString)/destinations.json").path
            }
        }
    }

    func read() throws -> DestinationConfig {
        guard FileManager.default.fileExists(atPath: configPath) else {
            return DestinationConfig()
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let config = try okdiskJSONDecoder().decode(DestinationConfig.self, from: data)
            guard config.schemaVersion == 1 else {
                throw OKDiskError.invalidConfig("Unsupported schema version \(config.schemaVersion)")
            }
            return DestinationConfig(schemaVersion: config.schemaVersion, destinationRoots: normalizeRootsPreservingOrder(config.destinationRoots))
        } catch let error as OKDiskError {
            throw error
        } catch {
            throw OKDiskError.invalidConfig("Could not read \(configPath): \(error.localizedDescription)")
        }
    }

    func write(_ config: DestinationConfig) throws {
        let normalized = DestinationConfig(schemaVersion: 1, destinationRoots: normalizeRootsPreservingOrder(config.destinationRoots))
        let data = try okdiskJSONEncoder(pretty: true).encode(normalized)
        try okdiskAtomicWrite(data, to: configPath)
    }

    func addRoot(_ root: String) throws -> [String] {
        let canonical = okdiskCanonicalExistingPath(root)
        var config = try read()
        let existing = Set(config.destinationRoots.map { okdiskCanonicalExistingPath($0) })
        if existing.contains(canonical) {
            throw OKDiskError.duplicateDestination(canonical)
        }
        config.destinationRoots.append(canonical)
        try write(config)
        return config.destinationRoots
    }

    func removeRoot(_ root: String) throws {
        let canonical = okdiskCanonicalExistingPath(root)
        var config = try read()
        config.destinationRoots.removeAll { okdiskCanonicalExistingPath($0) == canonical }
        try write(config)
    }

    private func normalizeRootsPreservingOrder(_ roots: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for root in roots {
            let canonical = okdiskCanonicalExistingPath(root)
            guard !seen.contains(canonical) else { continue }
            seen.insert(canonical)
            output.append(canonical)
        }
        return output
    }
}

struct StoreIdentity: Codable, Equatable {
    var schemaVersion: Int
    var storeID: String
    var createdAtUTC: String
    var createdByHostname: String
    var app: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case storeID = "store_id"
        case createdAtUTC = "created_at_utc"
        case createdByHostname = "created_by_hostname"
        case app
    }

    init(storeID: String = UUID().uuidString, hostname: String) {
        self.schemaVersion = 1
        self.storeID = storeID
        self.createdAtUTC = okdiskNowUTC()
        self.createdByHostname = hostname
        self.app = "OKDisk"
    }
}

struct DestinationContext: Equatable {
    var configuredRootPath: String
    var canonicalRootPath: String
    var identity: StoreIdentity
    var replay: ReplayResult
    var isWritable: Bool
    var status: DestinationStatus

    var storeID: String { identity.storeID }
    var metadataLogPath: String { canonicalRootPath + "/okdisk.metadata.jsonl" }
    var storeIdentityPath: String { canonicalRootPath + "/okdisk.store.json" }
    var dataRootPath: String { canonicalRootPath + "/data" }
    var tmpRootPath: String { canonicalRootPath + "/tmp" }

    func treeRoot(for folder: FolderConfig) -> String {
        dataRootPath + "/hosts/\(folder.hostname)/\(folder.folderID)/tree"
    }
}

enum DestinationStore {
    static func initialize(rootPath: String, hostname: String) throws -> DestinationContext {
        let fm = FileManager.default
        let standardized = okdiskStandardPath(rootPath)
        try okdiskEnsureDirectory(standardized)
        let canonical = okdiskCanonicalExistingPath(standardized)
        try okdiskEnsureDirectory(canonical + "/data")
        try okdiskEnsureDirectory(canonical + "/tmp")

        let storePath = canonical + "/okdisk.store.json"
        if !fm.fileExists(atPath: storePath) {
            let identity = StoreIdentity(hostname: hostname)
            let data = try okdiskJSONEncoder(pretty: true).encode(identity)
            try okdiskAtomicWrite(data, to: storePath)
        }

        let logPath = canonical + "/okdisk.metadata.jsonl"
        if !fm.fileExists(atPath: logPath) {
            try okdiskAtomicWrite(Data(), to: logPath)
        }

        return try loadExisting(rootPath: canonical)
    }

    static func loadExisting(rootPath: String) throws -> DestinationContext {
        let canonical = okdiskCanonicalExistingPath(rootPath)
        guard okdiskIsDirectory(canonical) else {
            throw OKDiskError.destinationUnavailable(rootPath)
        }
        let storePath = canonical + "/okdisk.store.json"
        let logPath = canonical + "/okdisk.metadata.jsonl"
        guard FileManager.default.fileExists(atPath: storePath) else {
            throw OKDiskError.destinationCorrupted("Missing okdisk.store.json at \(canonical)")
        }
        guard FileManager.default.fileExists(atPath: logPath) else {
            throw OKDiskError.destinationCorrupted("Missing okdisk.metadata.jsonl at \(canonical)")
        }
        let identity: StoreIdentity
        do {
            identity = try okdiskJSONDecoder().decode(StoreIdentity.self, from: Data(contentsOf: URL(fileURLWithPath: storePath)))
        } catch {
            throw OKDiskError.destinationCorrupted("Invalid store identity at \(canonical): \(error.localizedDescription)")
        }
        guard identity.schemaVersion == 1, identity.app == "OKDisk" else {
            throw OKDiskError.destinationCorrupted("Unsupported store identity at \(canonical)")
        }
        try okdiskEnsureDirectory(canonical + "/data")
        try okdiskEnsureDirectory(canonical + "/tmp")
        let replay = try MetadataLog.replay(path: logPath)
        let writable = isWritable(root: canonical)
        let status = DestinationStatus(
            rootPath: rootPath,
            canonicalRootPath: canonical,
            storeID: identity.storeID,
            state: replay.corruptLineCount > 0 ? .corrupted : .healthy,
            isWritable: writable,
            latestSyncRunSeq: replay.latestSyncRunSeq,
            skippedCorruptRecords: replay.corruptLineCount,
            skippedPartialRecord: replay.partialLastLineSkipped,
            message: replay.corruptLineCount > 0 ? "Metadata log contains corrupt records" : nil
        )
        return DestinationContext(
            configuredRootPath: rootPath,
            canonicalRootPath: canonical,
            identity: identity,
            replay: replay,
            isWritable: writable,
            status: status
        )
    }

    static func isWritable(root: String) -> Bool {
        let probe = root + "/.okdisk-write-probe-\(UUID().uuidString)"
        do {
            try Data("ok".utf8).write(to: URL(fileURLWithPath: probe))
            try FileManager.default.removeItem(atPath: probe)
            return true
        } catch {
            return false
        }
    }
}
