import Foundation

extension Foundation.Bundle {
    static let module: Bundle = {
        let mainPath = Bundle.main.bundleURL.appendingPathComponent("CassiniKit_CassiniLibrary.bundle").path
        let buildPath = "/private/var/folders/8t/fdtyk5ws5s54c6k8l_zz537c0000gn/T/cassini-real-paths-m05upb08/consumer/.build/arm64-apple-macosx/debug/CassiniKit_CassiniLibrary.bundle"

        let preferredBundle = Bundle(path: mainPath)

        guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
            // Users can write a function called fatalError themselves, we should be resilient against that.
            Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
        }

        return bundle
    }()
}