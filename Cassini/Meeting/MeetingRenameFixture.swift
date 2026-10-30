// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Writable copies for hosted UI tests, never the sealed app resources or a
/// user's Library. Production and ordinary screenshot launches cannot enable it.
enum MeetingRenameFixture {
    static var enabled: Bool {
        #if DEBUG
        id != nil
        #else
        false
        #endif
    }
    #if DEBUG
    static var id: UUID? {
        let env = ProcessInfo.processInfo.environment
        guard env["CASSINI_HOSTED_SCREENSHOTS"] == "1", CommandLine.arguments.contains("--fixture-library-rename"),
              let value = LibraryLaunchContext.argument("-CassiniRenameID") else { return nil }
        return UUID(uuidString:value)
    }
    static let root: URL? = {
        guard let id else { return nil }
        let name = LibraryLaunchContext.argument("-CassiniFixture").map { URL(fileURLWithPath:$0).lastPathComponent } ?? "main"
        guard ["main","received-only"].contains(name) else { return nil }
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Fixtures/Library/" + name + "/root")
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniRenameFixture-" + id.uuidString,isDirectory:true)
        let root = parent.appendingPathComponent("root",isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            if !FileManager.default.fileExists(atPath:root.path) { try FileManager.default.copyItem(at:source,to:root) }
            return root
        } catch { return nil }
    }()
    #endif
}
