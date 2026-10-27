// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import MachO

public struct VADAssets {
    public let library: URL
    public let model: URL
    public static func forWorker(arguments: [String]) throws -> Self {
        // Reuse the worker's signature and Whistle source-pin validation.
        _ = try WhistleAssets.forWorker(arguments: arguments)
        var count: UInt32 = 0; _ = _NSGetExecutablePath(nil, &count)
        var bytes = [CChar](repeating: 0, count: Int(count)); _ = _NSGetExecutablePath(&bytes, &count)
        let exe = URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath()
        let contents = exe.deletingLastPathComponent().deletingLastPathComponent()
        let bundled = exe.deletingLastPathComponent().lastPathComponent == "MacOS" && contents.lastPathComponent == "Contents"
        let root = bundled ? contents.appendingPathComponent("Resources/Whistle") : URL(fileURLWithPath: arguments[1]).resolvingSymlinksInPath()
        let library = bundled ? contents.appendingPathComponent("Frameworks/libonnxruntime.1.23.2.dylib") : root.appendingPathComponent("libonnxruntime.1.23.2.dylib")
        let model = root.appendingPathComponent("silero_vad.onnx")
        guard model.resolvingSymlinksInPath().path == model.path, library.resolvingSymlinksInPath().path == library.path,
              WhistleAssets.sha(try WhistleIO.readRegular(model, maximum: 3_000_000)) == "1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3" else { throw WhistleFailure.model("VAD checksum/path mismatch") }
        let hash = WhistleAssets.sha(try WhistleIO.readRegular(library, maximum: 100_000_000))
        if bundled {
            let manifest = try JSONDecoder().decode([String:String].self, from: WhistleIO.readRegular(root.appendingPathComponent("bundle-sha256.json"), maximum: 65536))
            guard manifest[library.lastPathComponent] == hash else { throw WhistleFailure.library("signed VAD runtime checksum mismatch") }
        } else {
            guard hash == "6fee21a0dbcaa98fe082cb4f7ed07ec5def439df36198f47b61dc205e7d2a1fa" else { throw WhistleFailure.library("VAD runtime source checksum mismatch") }
        }
        return .init(library: library, model: model)
    }
}
