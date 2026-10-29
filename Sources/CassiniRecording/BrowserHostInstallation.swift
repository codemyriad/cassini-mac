// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// macOS user-level Native Messaging registration. The shipped executable needs no compiler,
/// Python, or shell subprocess to install itself. Never changes browser profile preferences.
public struct BrowserHostInstallation {
    public static let hostName = "io.codemyriad.cassini"
    public static let browsers = ["Google/Chrome", "Chromium", "Microsoft Edge", "BraveSoftware/Brave-Browser"]
    public let supportDirectory: URL
    public let executable: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, executable: URL) {
        supportDirectory = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.executable = executable.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func install(extensionID: String) throws -> [URL] {
        guard extensionID.utf8.count == 32, extensionID.utf8.allSatisfy({ (97...112).contains($0) }) else {
            throw RecordingError.invalid("Copy the 32-letter extension ID from chrome://extensions (letters a–p).")
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw RecordingError.invalid("The bundled recording host is missing or is not executable.")
        }
        let bases = Self.browsers.map { supportDirectory.appendingPathComponent($0, isDirectory: true) }
            .filter { url in var directory: ObjCBool = false; return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue }
        guard !bases.isEmpty else {
            throw RecordingError.invalid("Open Chrome, Chromium, Edge or Brave once, then install the recording host again.")
        }
        let manifest: [String: Any] = ["name": Self.hostName, "description": "Cassini local meeting recorder",
            "path": executable.path, "type": "stdio", "allowed_origins": ["chrome-extension://\(extensionID)/"]]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        return try bases.map { base in
            let directory = base.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let target = directory.appendingPathComponent(Self.hostName + ".json")
            try data.write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return target
        }
    }

    public func uninstall() throws -> [URL] {
        var removed: [URL] = []
        for browser in Self.browsers {
            let target = supportDirectory.appendingPathComponent(browser).appendingPathComponent("NativeMessagingHosts/" + Self.hostName + ".json")
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
                removed.append(target)
            }
        }
        return removed
    }
}
