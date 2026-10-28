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
        if let bundle = assets.signedBundle { return try bundled(bundle) }
        return try pinned(directory:assets.resources)
    }
    public static func bundled(_ bundle: SignedSpeechBundle) throws -> Self {
        let library = try bundle.framework("libonnxruntime.1.23.2.dylib",manifest:"Whistle")
        let model = try bundle.resources("Whistle").appendingPathComponent("silero_vad.onnx")
        try validateModel(model)
        return .init(library:library,model:model)
    }
    public static func pinned(directory: URL) throws -> Self {
        let root = directory.resolvingSymlinksInPath(), library = root.appendingPathComponent("libonnxruntime.1.23.2.dylib")
        let model = root.appendingPathComponent("silero_vad.onnx")
        try validateModel(model)
        guard library.resolvingSymlinksInPath().path == library.path,
              WhistleAssets.sha(try WhistleIO.readRegular(library,maximum:100_000_000)) == "6fee21a0dbcaa98fe082cb4f7ed07ec5def439df36198f47b61dc205e7d2a1fa" else { throw WhistleFailure.library("VAD runtime source checksum mismatch") }
        return .init(library:library,model:model)
    }
    private static func validateModel(_ model: URL) throws {
        guard model.resolvingSymlinksInPath().path == model.path,
              WhistleAssets.sha(try WhistleIO.readRegular(model,maximum:3_000_000)) == "1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3" else { throw WhistleFailure.model("VAD checksum/path mismatch") }
    }
}
