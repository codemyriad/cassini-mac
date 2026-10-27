import CassiniRecording
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
            print("Browser recordings are saved in ~/Music/Cassini. Re-run setup after moving Cassini.app.")
        } else {
            throw RecordingError.invalid("Usage: cassini-browser-host --install-extension EXTENSION_ID | --uninstall-extension")
        }
        exit(0)
    } catch {
        try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
        exit(2)
    }
}

// stdout belongs exclusively to Chrome's length-prefixed protocol.
let destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Cassini", isDirectory: true)
let host = BrowserRecordingHost(parent: destination)
do {
    while let data = try NativeMessageFraming.read(from: .standardInput) {
        let response = try host.receive(data)
        try NativeMessageFraming.write(JSONSerialization.data(withJSONObject: response), to: .standardOutput)
    }
    try host.disconnect()
} catch {
    try? host.disconnect(problem: error.localizedDescription)
    let response = ["type": "error", "code": (error as? BrowserProtocolError)?.code ?? "io", "message": error.localizedDescription]
    if let data = try? JSONSerialization.data(withJSONObject: response) {
        try? NativeMessageFraming.write(data, to: .standardOutput)
    }
    exit(1)
}
