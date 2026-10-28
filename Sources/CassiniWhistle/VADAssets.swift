// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import MachO

public struct VADAssets {
    public let library: URL
    public let model: URL
    public static func forWorker(arguments: [String]) throws -> Self {
        try verified(for:WhistleAssets.forWorker(arguments:arguments))
    }
    /// The immutable capability's initializer is private to WhistleAssets. Its
    /// verified root/signature cannot be replaced with unchecked arguments.
    public static func verified(for assets: WhistleAssets) throws -> Self {
        let root = assets.resources
        let library = assets.bundleContents?.appendingPathComponent("Frameworks/libonnxruntime.1.23.2.dylib") ?? root.appendingPathComponent("libonnxruntime.1.23.2.dylib")
        let model = root.appendingPathComponent("silero_vad.onnx")
        guard model.resolvingSymlinksInPath().path == model.path, library.resolvingSymlinksInPath().path == library.path,
              WhistleAssets.sha(try WhistleIO.readRegular(model, maximum: 3_000_000)) == "1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3" else { throw WhistleFailure.model("VAD checksum/path mismatch") }
        let hash = WhistleAssets.sha(try WhistleIO.readRegular(library, maximum: 100_000_000))
        if assets.bundleContents != nil {
            let manifest = try JSONDecoder().decode([String:String].self, from: WhistleIO.readRegular(root.appendingPathComponent("bundle-sha256.json"), maximum: 65536))
            guard manifest[library.lastPathComponent] == hash else { throw WhistleFailure.library("signed VAD runtime checksum mismatch") }
        } else {
            guard hash == "6fee21a0dbcaa98fe082cb4f7ed07ec5def439df36198f47b61dc205e7d2a1fa" else { throw WhistleFailure.library("VAD runtime source checksum mismatch") }
        }
        return .init(library: library, model: model)
    }
}
