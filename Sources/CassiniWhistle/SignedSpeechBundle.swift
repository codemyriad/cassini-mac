// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security
import MachO

/// One immutable app-seal check shared by a worker's recognizer and Silero.
/// The capability can only be created for the actual executing speech helper.
public struct SignedSpeechBundle {
    public let app: URL
    public let executable: URL
    private let namespace: String
    private init(app: URL, executable: URL, namespace: String) { self.app = app; self.executable = executable; self.namespace = namespace }
    public static func currentWorker() throws -> Self {
        var count: UInt32 = 0
        _ = _NSGetExecutablePath(nil,&count)
        var bytes = [CChar](repeating:0,count:Int(count))
        guard _NSGetExecutablePath(&bytes,&count) == 0 else { throw WhistleFailure.library("worker path unavailable") }
        let executable = URL(fileURLWithPath:String(decoding:bytes.prefix { $0 != 0 }.map { UInt8(bitPattern:$0) },as:UTF8.self)).resolvingSymlinksInPath()
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent(), app = contents.deletingLastPathComponent()
        let names = ["cassini-whistle-worker":"Whistle","cassini-parakeet-worker":"Parakeet"]
        guard let namespace = names[executable.lastPathComponent], executable.deletingLastPathComponent().lastPathComponent == "MacOS",
              contents.lastPathComponent == "Contents", app.pathExtension == "app" else { throw WhistleFailure.library("not a bundled speech helper") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL,[],&code) == errSecSuccess, let code else { throw WhistleFailure.library("bundle signature unavailable") }
        let flags = SecCSFlags(rawValue:kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code,flags,nil)
        guard status == errSecSuccess else { throw WhistleFailure.library("bundle signature/resource verification failed: \(status)") }
        let result = Self(app:app,executable:executable,namespace:namespace)
        guard try result.manifest(namespace)[executable.lastPathComponent] == WhistleAssets.sha(WhistleIO.readRegular(executable,maximum:64 << 20)) else {
            throw WhistleFailure.library("signed worker checksum mismatch")
        }
        return result
    }
    public func resources(_ name: String) throws -> URL { try contained("Contents/Resources/" + name) }
    public func manifest(_ name: String) throws -> [String:String] {
        let file = try contained("Contents/Resources/" + name + "/bundle-sha256.json")
        return try JSONDecoder().decode([String:String].self,from:WhistleIO.readRegular(file,maximum:65536))
    }
    public func framework(_ name: String, manifest namespace: String) throws -> URL {
        let file = try contained("Contents/Frameworks/" + name)
        guard try manifest(namespace)[name] == WhistleAssets.sha(WhistleIO.readRegular(file,maximum:128 << 20)) else { throw WhistleFailure.library("signed engine checksum mismatch") }
        return file
    }
    private func contained(_ path: String) throws -> URL {
        let file = app.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(app.path + "/"), file.resolvingSymlinksInPath().path == file.path else { throw WhistleFailure.library("bundle asset symlink/path mismatch") }
        return file
    }
}
