// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Security
import MachO

/// Source pins are compiled into the worker; an arbitrary adjacent manifest
/// cannot authorise a different standalone library or model.
enum WhistlePins {
    static let model = "b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb"
    static let libraries: [UInt32: String] = [
        0x0100000c: "99b9bd363d2e247626118e7ade04a3dc70c60ebe6bbb0e1bca50bc0bce24b0d3",
        0x01000007: "0ea5cf58a46145ce146b7e6d9f9d945132a13c1e6eeb0401ce27182e6e2a846a"
    ]
}
public struct WhistleAssets {
    /// Source identity for diagnostics and narrowly scoped golden policy. Both
    /// standalone original slices and sealed bundles are validated below.
    public static var sourcePins: [String:String] {
        ["engineVersion":"3.3.0", "modelSha256":WhistlePins.model,
         "arm64LibrarySha256":WhistlePins.libraries[0x0100000c]!,
         "x86_64LibrarySha256":WhistlePins.libraries[0x01000007]!]
    }
    let library: URL
    let model: Data
    private init(library: URL, model: Data) { self.library = library; self.model = model }
    public static func forWorker(arguments: [String]) throws -> Self {
        var count: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &count)
        var buffer = [CChar](repeating: 0, count: Int(count))
        guard _NSGetExecutablePath(&buffer, &count) == 0 else { throw WhistleFailure.library("executable path unavailable") }
        let executable = URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).resolvingSymlinksInPath()
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        if executable.deletingLastPathComponent().lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
           contents.deletingLastPathComponent().pathExtension == "app" {
            guard arguments.isEmpty else { throw WhistleFailure.library("bundled worker does not accept asset paths") }
            return try bundled(app: contents.deletingLastPathComponent(), executable: executable)
        }
        guard arguments.count == 2, arguments[0] == "--assets" else { throw WhistleFailure.library("standalone worker requires --assets DIRECTORY") }
        return try pinned(directory: URL(fileURLWithPath: arguments[1]))
    }
    /// The standalone test tool accepts only the original, source-pinned slices.
    public static func pinned(directory: URL) throws -> Self {
        let root = directory.resolvingSymlinksInPath()
        let library = try contained("libneedle3.dylib", in: root)
        let bytes = try WhistleIO.readRegular(library, maximum: 16 * 1024 * 1024)
        try verifySourceLibrary(bytes)
        let model = try modelBytes(at: contained("whistle.cact", in: root))
        return .init(library: library, model: model)
    }
    private static func bundled(app: URL, executable: URL) throws -> Self {
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard created == errSecSuccess, let code else { throw WhistleFailure.library("bundle signature unavailable: \(created)") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        guard status == errSecSuccess else { throw WhistleFailure.library("bundle signature/resource verification failed: \(status)") }
        let resource = try contained("Contents/Resources/Whistle", in: app)
        let manifest = try JSONDecoder().decode([String: String].self, from: WhistleIO.readRegular(try contained("bundle-sha256.json", in: resource), maximum: 65536))
        let library = try contained("Contents/Frameworks/libneedle3.dylib", in: app)
        let libraryBytes = try WhistleIO.readRegular(library, maximum: 16 * 1024 * 1024)
        let model = try modelBytes(at: contained("whistle.cact", in: resource))
        guard manifest["libneedle3.dylib"] == sha(libraryBytes), manifest["whistle.cact"] == WhistlePins.model,
              manifest["cassini-whistle-worker"] == sha(try WhistleIO.readRegular(executable, maximum: 64 * 1024 * 1024)) else {
            throw WhistleFailure.library("signed bundle checksum mismatch")
        }
        return .init(library: library, model: model)
    }
    private static func contained(_ path: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/"), resolved.path == url.path else {
            throw WhistleFailure.library("asset path escapes its directory or is a symlink")
        }
        return url
    }
    private static func modelBytes(at url: URL) throws -> Data {
        let bytes = try WhistleIO.readRegular(url, maximum: 64 * 1024 * 1024)
        guard sha(bytes) == WhistlePins.model else { throw WhistleFailure.model("source checksum mismatch") }
        return bytes
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func verifySourceLibrary(_ bytes: Data) throws {
        func be32(_ offset: Int) -> UInt32 { bytes.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) } }
        func be64(_ offset: Int) -> UInt64 { bytes.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) } }
        guard bytes.count >= 8 else { throw WhistleFailure.library("source checksum mismatch") }
        let magic = be32(0)
        if magic == 0xcafebabe || magic == 0xcafebabf {
            let entry = magic == 0xcafebabe ? 20 : 32
            guard be32(4) == 2, bytes.count >= 8 + 2 * entry else { throw WhistleFailure.library("unexpected source architectures") }
            var found = Set<UInt32>()
            for index in 0..<2 {
                let at = 8 + index * entry, cpu = be32(at)
                let offset = entry == 20 ? UInt64(be32(at + 8)) : be64(at + 8)
                let size = entry == 20 ? UInt64(be32(at + 12)) : be64(at + 16)
                guard offset >= UInt64(8 + 2 * entry), offset <= UInt64(bytes.count), size <= UInt64(bytes.count) - offset,
                      let expected = WhistlePins.libraries[cpu], found.insert(cpu).inserted,
                      sha(Data(bytes[Int(offset)..<Int(offset + size)])) == expected else { throw WhistleFailure.library("source checksum mismatch") }
            }
        } else {
            guard WhistlePins.libraries.values.contains(sha(bytes)) else { throw WhistleFailure.library("source checksum mismatch") }
        }
    }
}
