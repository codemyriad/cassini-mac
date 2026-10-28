// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Security
import MachO
import Darwin

public enum ParakeetFailure: Error { case privacy, runtime(String), invalidModel, invalidRuntime, invalidAudio, invalidTokens }
public enum ParakeetPin {
    public static let id = "parakeet-ultra-0.6b-int8"
    public static let sourceSHA256 = "18cb623004dd6c15999b93cb70b14d8a1f6e8f3a2a97ff733f104bfc3494f6a9"
    public static let transcriptModel = id + "@" + sourceSHA256
    public static let files: [String:(bytes:UInt64,sha256:String)] = [
        "encoder.int8.onnx":(652282922,"299617fefd4664d1c115b691dcb6413cabcdbcc694cdf3cb4464b72c5fc3ae69"),
        "decoder.int8.onnx":(11845274,"1fab98fe6c12aded87d2da66272cc9e148d0a0044ce3850a12fe56302ec4a922"),
        "joiner.int8.onnx":(6355277,"8a71aaccfdba3d451775507a889afd2257d2e754463fd81095a8c8f290f924c2"),
        "tokens.txt":(93939,"d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d")
    ]
    static let runtimes: [String:[UInt32:String]] = [
        "libsherpa-onnx-c-api.dylib":[0x0100000c:"77914d7a1e00a7ed220dbefbd36826ac1b2c32a218a1fb7b7a08ee5524ecd654",0x01000007:"4bc86777a9ef6ecc2bff91eafb6e5192e2aeca396a11104651a8cfe26267e616"],
        "libonnxruntime.dylib":[0x0100000c:"f1217a893bd4e619022264dbc4bad3490866552b48926ee4c09243e9200b4c53",0x01000007:"8dc3d87827183d659f65fc526bd9ea06ad7e9bd906b16bdae26338d3ef26863e"]
    ]
}
/// Validated before dlopen or model parsing. An adjacent, writable checksum
/// manifest never authorises a standalone runtime or a different model.
public struct ParakeetAssets {
    let library: URL
    let ort: URL
    let model: URL
    private init(library: URL, ort: URL, model: URL) { self.library = library; self.ort = ort; self.model = model }
    public static func forWorker(arguments: [String]) throws -> Self {
        var count: UInt32 = 0
        _ = _NSGetExecutablePath(nil,&count)
        var buffer = [CChar](repeating:0,count:Int(count))
        guard _NSGetExecutablePath(&buffer,&count) == 0 else { throw ParakeetFailure.invalidRuntime }
        let executable = URL(fileURLWithPath:String(decoding:buffer.prefix { $0 != 0 }.map { UInt8(bitPattern:$0) },as:UTF8.self)).resolvingSymlinksInPath()
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        if executable.deletingLastPathComponent().lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", contents.deletingLastPathComponent().pathExtension == "app" {
            guard arguments.count == 2, arguments[0] == "--model" else { throw ParakeetFailure.invalidRuntime }
            return try bundled(app:contents.deletingLastPathComponent(),executable:executable,model:URL(fileURLWithPath:arguments[1]))
        }
        guard arguments.count == 4, arguments[0] == "--runtime", arguments[2] == "--model" else { throw ParakeetFailure.invalidRuntime }
        return try pinned(runtime:URL(fileURLWithPath:arguments[1]),model:URL(fileURLWithPath:arguments[3]))
    }
    public static func pinned(runtime: URL, model: URL) throws -> Self {
        let root = runtime.resolvingSymlinksInPath()
        for (name,pins) in ParakeetPin.runtimes {
            let bytes = try regularData(contained(name,in:root),maximum:128 << 20)
            try verifySourceLibrary(bytes,pins:pins)
        }
        return try validated(runtime:root,model:model)
    }
    private static func bundled(app: URL, executable: URL, model: URL) throws -> Self {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL,[],&code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode),nil) == errSecSuccess else { throw ParakeetFailure.invalidRuntime }
        let root = try contained("Contents/Frameworks/Parakeet",in:app)
        let resources = try contained("Contents/Resources/Parakeet",in:app)
        let manifest = try JSONDecoder().decode([String:String].self,from:regularData(contained("bundle-sha256.json",in:resources),maximum:65536))
        for name in ParakeetPin.runtimes.keys {
            guard manifest[name] == sha(try regularData(contained(name,in:root),maximum:128 << 20)) else { throw ParakeetFailure.invalidRuntime }
        }
        let expectedExecutable = try contained("Contents/MacOS/cassini-parakeet-worker",in:app)
        guard executable.lastPathComponent == "cassini-parakeet-worker",
              executable.standardizedFileURL.path == expectedExecutable.path,
              manifest["cassini-parakeet-worker"] == sha(try regularData(executable,maximum:64 << 20)) else { throw ParakeetFailure.invalidRuntime }
        return try validated(runtime:root,model:model)
    }
    private static func validated(runtime: URL, model: URL) throws -> Self {
        let root = model.resolvingSymlinksInPath()
        for (name,pin) in ParakeetPin.files {
            let file = try contained(name,in:root)
            guard try digest(file,size:pin.bytes) == pin.sha256 else { throw ParakeetFailure.invalidModel }
        }
        return .init(library:try contained("libsherpa-onnx-c-api.dylib",in:runtime),ort:try contained("libonnxruntime.dylib",in:runtime),model:root)
    }
    private static func contained(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), url.resolvingSymlinksInPath().path == url.path else { throw ParakeetFailure.invalidRuntime }
        return url
    }
    private static func opened(_ url: URL, maximum: UInt64, exact: UInt64? = nil) throws -> FileHandle {
        let fd = open(url.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ParakeetFailure.invalidModel }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
              UInt64(info.st_size) <= maximum, exact.map({ UInt64(info.st_size) == $0 }) ?? true else { close(fd); throw ParakeetFailure.invalidModel }
        return FileHandle(fileDescriptor:fd,closeOnDealloc:true)
    }
    private static func regularData(_ url: URL, maximum: UInt64) throws -> Data {
        let file = try opened(url,maximum:maximum); defer { try? file.close() }
        let data = try file.readToEnd() ?? Data()
        guard UInt64(data.count) <= maximum else { throw ParakeetFailure.invalidRuntime }; return data
    }
    private static func digest(_ url: URL, size: UInt64) throws -> String {
        let file = try opened(url,maximum:size,exact:size); defer { try? file.close() }
        var hash = SHA256(), total: UInt64 = 0
        while let bytes = try file.read(upToCount:1 << 20), !bytes.isEmpty {
            try Task.checkCancellation(); total += UInt64(bytes.count)
            guard total <= size else { throw ParakeetFailure.invalidModel }; hash.update(data:bytes)
        }
        guard total == size else { throw ParakeetFailure.invalidModel }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func verifySourceLibrary(_ data: Data, pins: [UInt32:String]) throws {
        guard data.count >= 8 else { throw ParakeetFailure.invalidRuntime }
        func be32(_ n: Int) -> UInt32 { data.withUnsafeBytes { UInt32(bigEndian:$0.loadUnaligned(fromByteOffset:n,as:UInt32.self)) } }
        func be64(_ n: Int) -> UInt64 { data.withUnsafeBytes { UInt64(bigEndian:$0.loadUnaligned(fromByteOffset:n,as:UInt64.self)) } }
        let magic = be32(0)
        if magic != 0xcafebabe && magic != 0xcafebabf {
            guard pins.values.contains(sha(data)) else { throw ParakeetFailure.invalidRuntime }; return
        }
        let width = magic == 0xcafebabe ? 20 : 32, header = 8 + 2 * width
        guard be32(4) == 2, data.count >= header else { throw ParakeetFailure.invalidRuntime }
        var found = Set<UInt32>()
        for index in 0..<2 {
            let at = 8 + index * width, cpu = be32(at)
            let offset = width == 20 ? UInt64(be32(at+8)) : be64(at+8)
            let size = width == 20 ? UInt64(be32(at+12)) : be64(at+16)
            guard let expected = pins[cpu], found.insert(cpu).inserted, offset >= UInt64(header),
                  offset <= UInt64(data.count), size <= UInt64(data.count) - offset,
                  sha(Data(data[Int(offset)..<Int(offset+size)])) == expected else { throw ParakeetFailure.invalidRuntime }
        }
    }
}
