// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

public struct ModelPin: Hashable, Codable, Sendable {
    public let id: String
    public let sourceSHA256: String
    public init(id: String, sourceSHA256: String) { self.id = id; self.sourceSHA256 = sourceSHA256 }
    public var valid: Bool { Self.identifier(id) && Self.hash(sourceSHA256) }
    static func hash(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 } && value.first != "." && !value.contains("..")
    }
}
public enum ModelDownloadError: Error, Equatable, Sendable {
    case manifest, pinUnavailable, unsafePath, origin, response, etag, range, tooLarge, truncated, hash, zstd, diskSpace(required:UInt64,available:UInt64), busy, installation
}
public struct ModelAsset: Codable, Sendable, Equatable {
    public let path: String
    public let url: URL
    public let compressedBytes: UInt64
    public let compressedSHA256: String
    public let rawBytes: UInt64
    public let rawSHA256: String
}
public struct ModelPlan: Sendable {
    public let pin: ModelPin
    public let files: [ModelAsset]
    public var compressedBytes: UInt64 { files.reduce(0) { $0 + $1.compressedBytes } }
    public var rawBytes: UInt64 { files.reduce(0) { $0 + $1.rawBytes } }
    // Reserve both a complete partial download and a decoded staging copy, plus
    // bounded metadata/NOTICE. A previously installed revision is not removed.
    public var spaceRequired: UInt64 { compressedBytes + rawBytes + (8 << 20) }
}
struct ModelOrigin: Sendable {
    let base: URL
    init(_ base: URL, fixture: Bool = false) throws {
        guard base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              base.path == "" || base.path == "/" else { throw ModelDownloadError.origin }
        if fixture {
            guard base.scheme == "http", base.host == "127.0.0.1", base.port != nil else { throw ModelDownloadError.origin }
        } else {
            guard base.absoluteString == "https://dist.gocassini.com" else { throw ModelDownloadError.origin }
        }
        self.base = base
    }
    func permits(_ url: URL) -> Bool {
        url.scheme == base.scheme && url.host == base.host && url.port == base.port && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }
    func endpoint(_ path: String) -> URL { base.appendingPathComponent(path) }
}
public enum ModelManifest {
    public static func plan(_ data: Data, pin: ModelPin) throws -> ModelPlan {
        try plan(data,pin:pin,origin:ModelOrigin(URL(string:"https://dist.gocassini.com")!))
    }
    static func pathValid(_ path: String) -> Bool {
        let parts = path.split(separator:"/",omittingEmptySubsequences:false)
        return !parts.isEmpty && parts.count <= 16 && path.utf8.count <= 1024 && !path.contains("\\") &&
            parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && $0.utf8.count <= 255 && !$0.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } } &&
            parts.first != "NOTICE.txt" && parts.first != "receipt.json"
    }
    static func plan(_ data: Data, pin: ModelPin, origin: ModelOrigin) throws -> ModelPlan {
        guard pin.valid, data.count <= 4 << 20 else { throw ModelDownloadError.manifest }
        let json = try JSONParser.parse(data)
        guard json["schema_version"]?.int == 2, json["base_url"]?.string.map({ URL(string:$0) == origin.base }) == true,
              let models = json["models"]?.array, let artifacts = json["artifacts"]?.array,
              models.count <= 1024, artifacts.count <= 16384 else { throw ModelDownloadError.manifest }
        var keys = Set<String>(), ids = Set<String>()
        for model in models { guard let id = model["id"]?.string, ids.insert(id).inserted else { throw ModelDownloadError.manifest } }
        for artifact in artifacts { guard let key = artifact["key"]?.string, keys.insert(key).inserted else { throw ModelDownloadError.manifest } }
        guard let model = models.first(where:{ $0["id"]?.string == pin.id && $0["source_sha256"]?.string == pin.sourceSHA256 }),
              let files = model["files"]?.array, !files.isEmpty, files.count <= 256 else { throw ModelDownloadError.pinUnavailable }
        var output: [ModelAsset] = [], paths = Set<String>()
        for file in files {
            guard let path = file["path"]?.string, pathValid(path), paths.insert(path).inserted,
                  file["required"]?.bool != nil, let key = file["artifact"]?.string,
                  let object = artifacts.first(where:{ $0["key"]?.string == key }),
                  let rawURL = object["url"]?.string, let url = URL(string:rawURL), origin.permits(url),
                  let compressed = object["sha256"]?.string, ModelPin.hash(compressed),
                  let raw = object["uncompressed_sha256"]?.string, ModelPin.hash(raw),
                  let size = object["size"]?.int, size > 0, size <= 16 << 30,
                  let decoded = object["uncompressed_size"]?.int, decoded > 0, decoded <= 64 << 30,
                  object["encoding"]?.string == "zstd-seekable", object["format_version"]?.string == "0.1.0",
                  key == "models/files/" + compressed + "/" + path.split(separator:"/").last! + ".zst",
                  url == origin.endpoint(key) else { throw ModelDownloadError.manifest }
            output.append(.init(path:path,url:url,compressedBytes:UInt64(size),compressedSHA256:compressed,rawBytes:UInt64(decoded),rawSHA256:raw))
        }
        guard output.allSatisfy({ file in !output.contains { $0.path != file.path && file.path.hasPrefix($0.path + "/") } }),
              output.reduce(UInt64(0),{ $0 + $1.compressedBytes + $1.rawBytes }) < 128 << 30 else { throw ModelDownloadError.manifest }
        return .init(pin:pin,files:output)
    }
}
