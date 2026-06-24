import CryptoKit
import Darwin
import Foundation

public func okdiskCanonicalExistingPath(_ path: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    if realpath(path, &buffer) != nil {
        return String(cString: buffer)
    }
    return URL(fileURLWithPath: path).standardizedFileURL.path
}

func okdiskStandardPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}

public func okdiskCurrentHostname() -> String {
    var name = [CChar](repeating: 0, count: 256)
    if gethostname(&name, name.count) == 0 {
        let value = String(cString: name).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !value.isEmpty { return value }
    }
    return Host.current().localizedName?.lowercased() ?? "localhost"
}

public func okdiskNowUTC() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

func okdiskFileSafeTimestampUTC() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss-SSS'Z'"
    return formatter.string(from: Date())
}

func okdiskSHA256Hex(_ string: String) -> String {
    let digest = SHA256.hash(data: Data(string.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

func okdiskSHA256Hex(fileAt path: String) throws -> String {
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

public func okdiskFolderID(hostname: String, sourcePath: String) -> String {
    let key = hostname.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) + "\u{0}" + okdiskCanonicalExistingPath(sourcePath)
    return okdiskSHA256Hex("okdisk.folder.v1" + "\u{0}" + key)
}

func okdiskEnsureDirectory(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

func okdiskAtomicWrite(_ data: Data, to path: String) throws {
    let fm = FileManager.default
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    try okdiskEnsureDirectory(parent)
    let tmp = parent + "/.\(URL(fileURLWithPath: path).lastPathComponent).tmp-\(UUID().uuidString)"
    fm.createFile(atPath: tmp, contents: data)
    if let handle = FileHandle(forWritingAtPath: tmp) {
        try handle.synchronize()
        try handle.close()
    }
    if rename(tmp, path) != 0 {
        let err = errno
        try? fm.removeItem(atPath: tmp)
        throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
    }
    okdiskFsyncDirectory(parent)
}

func okdiskAppendLine(_ data: Data, to path: String) throws {
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    try okdiskEnsureDirectory(parent)
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()
    okdiskFsyncDirectory(parent)
}

func okdiskFsyncDirectory(_ path: String) {
    let fd = open(path, O_RDONLY)
    if fd >= 0 {
        _ = fsync(fd)
        _ = close(fd)
    }
}

func okdiskFsyncFile(_ path: String) {
    let fd = open(path, O_RDONLY)
    if fd >= 0 {
        _ = fsync(fd)
        _ = close(fd)
    }
}

func okdiskValidateRelativePath(_ raw: String, allowEmpty: Bool = false) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        if allowEmpty { return "" }
        throw OKDiskError.invalidPath("Relative path is empty")
    }
    if trimmed.hasPrefix("/") {
        throw OKDiskError.invalidPath("Relative path must not be absolute: \(raw)")
    }
    let normalizedSeparators = trimmed.replacingOccurrences(of: "\\", with: "/")
    var components: [String] = []
    for component in normalizedSeparators.split(separator: "/", omittingEmptySubsequences: true) {
        if component == "." { continue }
        if component == ".." {
            throw OKDiskError.invalidPath("Relative path must not traverse outside restore root: \(raw)")
        }
        components.append(String(component))
    }
    if components.isEmpty {
        if allowEmpty { return "" }
        throw OKDiskError.invalidPath("Relative path is empty")
    }
    return components.joined(separator: "/")
}

func okdiskRelativePath(path: String, base: String) throws -> String {
    let canonicalBase = okdiskCanonicalExistingPath(base)
    let canonicalPath = okdiskCanonicalExistingPath(path)
    if canonicalPath == canonicalBase { return "" }
    let prefix = canonicalBase.hasSuffix("/") ? canonicalBase : canonicalBase + "/"
    guard canonicalPath.hasPrefix(prefix) else {
        throw OKDiskError.invalidPath("Path \(canonicalPath) is not under base \(canonicalBase)")
    }
    let rel = String(canonicalPath.dropFirst(prefix.count))
    return try okdiskValidateRelativePath(rel)
}

func okdiskShouldSkipRelativePath(_ rel: String, excludedPatterns: [String]) -> Bool {
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

func okdiskPathExists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}

func okdiskIsDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

func okdiskRemoveItemIfExists(_ path: String) throws {
    if FileManager.default.fileExists(atPath: path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
        try FileManager.default.removeItem(atPath: path)
    }
}

func okdiskJSONEncoder(pretty: Bool = false) -> JSONEncoder {
    let encoder = JSONEncoder()
    if pretty {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    } else {
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }
    return encoder
}

func okdiskJSONDecoder() -> JSONDecoder {
    JSONDecoder()
}

extension Array where Element == String {
    func okdiskSortedUnique() -> [String] {
        Array(Set(self)).sorted()
    }
}
