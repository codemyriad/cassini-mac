// SPDX-License-Identifier: GPL-3.0-or-later
import CassiniRecording
import CassiniBrowserControl
import CassiniLibrary
import Foundation
import MachO

// Explicit setup mode is separate from Chrome's framed stdio mode. Chrome passes its
// extension origin as an argument; it is deliberately not treated as an installer option.
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--install-extension" || arguments.first == "--uninstall-extension" {
    do {
        // Bundle.main may identify Cassini.app and return its GUI executable. Register the
        // actual running helper, including when it lives inside that app bundle.
        var length: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &length)
        var buffer = [CChar](repeating: 0, count: Int(length))
        guard _NSGetExecutablePath(&buffer, &length) == 0 else { throw RecordingError.invalid("Cannot locate the recording host executable.") }
        let executable = URL(fileURLWithPath: String(cString: buffer))
        let installer = BrowserHostInstallation(executable: executable)
        if arguments == ["--uninstall-extension"] {
            let removed = try installer.uninstall()
            print("Removed \(removed.count) Cassini browser registrations. Recordings were retained.")
        } else if arguments.count == 2, arguments[0] == "--install-extension" {
            let paths = try installer.install(extensionID: arguments[1])
            print("Installed Cassini recording host for \(paths.count) existing browser profile directories.")
            for path in paths { print(path.path) }
            print("Browser recordings are saved in \(try LibraryLocation.read().primaryPath). Re-run setup after moving Cassini.app.")
        } else {
            throw RecordingError.invalid("Usage: cassini-browser-host --install-extension EXTENSION_ID | --uninstall-extension")
        }
        exit(0)
    } catch {
        try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
        exit(2)
    }
}

/// conformance/run.py gives every case a private Library through the test-only
/// CASSINI_LIBRARY_DIR. A Debug host honours it, so request-derived cases never write
/// into the user's Library; set but not an existing absolute directory, recording is
/// refused rather than falling back to the real Library. Release hosts ignore it.
func testLibrary() throws -> URL? {
    #if DEBUG
    guard let path = ProcessInfo.processInfo.environment["CASSINI_LIBRARY_DIR"] else { return nil }
    var directory: ObjCBool = false
    guard path.hasPrefix("/"), FileManager.default.fileExists(atPath:path,isDirectory:&directory), directory.boolValue else {
        throw RecordingError.invalid("CASSINI_LIBRARY_DIR is not an existing absolute directory.")
    }
    return URL(fileURLWithPath:path,isDirectory:true)
    #else
    return nil
    #endif
}

// stdout belongs exclusively to Chrome's length-prefixed protocol.
var host: BrowserRecordingHost?
do {
    let first = try NativeMessageFraming.read(from:.standardInput)
    if let first, BrowserAudioHost.usesBroker(first) { exit(BrowserAudioHost.run(firstRequest:first)) }
    let connection = arguments.first?.hasPrefix("chrome-extension://") == true
        ? try? BrowserCompanionConnection(browser:BrowserCompanionConnection.parentBrowserName) : nil
    defer { withExtendedLifetime(connection) {} }
    let recorder = BrowserRecordingHost { title in
        if let library = try testLibrary() { return try RecordingSession(parent:library,title:title,source:"chromium") }
        return try LibraryRouting.withLock(exclusive:false) {
            try RecordingSession(parent:LibraryRouting.recordingDestination(),title:title,source:"chromium")
        }
    }; host = recorder

    func respond(_ data: Data) throws {
        let response = try recorder.receive(data)
        try? connection?.update(recordingDirectory:recorder.session?.manifest.state == "recording" ? recorder.session?.directory : nil)
        try NativeMessageFraming.write(JSONSerialization.data(withJSONObject:response),to:.standardOutput)
    }
    if let first { try respond(first) }
    while let data = try NativeMessageFraming.read(from:.standardInput) { try respond(data) }
    try recorder.disconnect()
} catch {
    try? host?.disconnect(problem: error.localizedDescription)
    let response = ["type": "error", "code": (error as? BrowserProtocolError)?.code ?? "io", "message": error.localizedDescription]
    if let data = try? JSONSerialization.data(withJSONObject: response) {
        try? NativeMessageFraming.write(data, to: .standardOutput)
    }
    exit(1)
}
