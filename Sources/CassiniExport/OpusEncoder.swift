// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security
import CryptoKit
import Darwin
import CassiniLibrary
import CassiniOpus

public enum MeetingExportError: Error { case invalidSource, invalidAssets, encoding(String), tooLarge }
public struct OpusAssets {
    public static let sourceSHA256 = "6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
    let library: URL
    private init(library: URL) { self.library = library }
    public static func bundled(app: URL) throws -> Self {
        let root = app.resolvingSymlinksInPath()
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(root as CFURL,[],&code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode),nil) == errSecSuccess else { throw MeetingExportError.invalidAssets }
        let resource = root.appendingPathComponent("Contents/Resources/Opus")
        try validatePin(resource)
        let library = root.appendingPathComponent("Contents/Frameworks/libopus.0.dylib")
        let manifest = try JSONDecoder().decode([String:String].self,from:regular(resource.appendingPathComponent("bundle-sha256.json"),limit:65536))
        let actual = SHA256.hash(data:try regular(library,limit:8 * 1024 * 1024)).map { String(format:"%02x",$0) }.joined()
        guard manifest["libopus.0.dylib"] == actual else { throw MeetingExportError.invalidAssets }
        return .init(library:library)
    }
    /// Offline tests pass the hash from a fresh verified-source build. The app
    /// uses bundled(app:), and has no environment/path override for its engine.
    public static func builtForTests(directory: URL, expectedBinarySHA256: String) throws -> Self {
        try validatePin(directory)
        let library = directory.appendingPathComponent("libopus.0.dylib")
        let actual = SHA256.hash(data:try regular(library,limit:8 * 1024 * 1024)).map { String(format:"%02x",$0) }.joined()
        guard expectedBinarySHA256 == actual else { throw MeetingExportError.invalidAssets }
        return .init(library:library)
    }
    private static func validatePin(_ directory: URL) throws {
        struct Pin: Decodable { struct Source: Decodable { let sha256: String }; let version: String; let source: Source }
        let pin = try JSONDecoder().decode(Pin.self,from:regular(directory.appendingPathComponent("pins.json"),limit:65536))
        guard pin.version == "1.6.1", pin.source.sha256 == sourceSHA256 else { throw MeetingExportError.invalidAssets }
    }
    private static func regular(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw MeetingExportError.invalidAssets }; defer { close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= limit else { throw MeetingExportError.invalidAssets }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        let data = try handle.read(upToCount:limit + 1) ?? Data()
        guard data.count <= limit else { throw MeetingExportError.invalidAssets }; return data
    }
}

/// Confined to one synchronous export operation. No audio device is opened.
public final class OpusEncoder {
    private let handle: OpaquePointer
    public let preSkip: Int
    public init(assets: OpusAssets, choice: AudioEncodeChoice) throws {
        guard (6000...510000).contains(choice.bitrateBps), [4000,6000,8000,12000,20000].contains(choice.cutoffHz) else { throw MeetingExportError.invalidSource }
        var error = [CChar](repeating:0,count:2048), lookahead: Int32 = 0
        let pointer = assets.library.path.withCString {
            cassini_opus_create($0,Int32(choice.bitrateBps),Int32(choice.cutoffHz),&lookahead,&error,error.count)
        }
        guard let pointer else { throw MeetingExportError.encoding(String(cString:error)) }
        guard (0...5760).contains(lookahead) else { cassini_opus_destroy(pointer); throw MeetingExportError.invalidAssets }
        handle = pointer; preSkip = Int(lookahead)
    }
    deinit { cassini_opus_destroy(handle) }
    public func encode(_ samples: [Float]) throws -> Data {
        var output = [UInt8](repeating:0,count:4096), error = [CChar](repeating:0,count:2048)
        let count = cassini_opus_encode(handle,samples,samples.count,&output,output.count,&error,error.count)
        guard count > 0 else { throw MeetingExportError.encoding(String(cString:error)) }
        return Data(output.prefix(Int(count)))
    }
}
