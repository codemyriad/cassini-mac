import CassiniRecording
import Foundation

// stdout belongs exclusively to Chrome's length-prefixed protocol.
let destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Cassini", isDirectory: true)
let host = BrowserRecordingHost(parent: destination)
do {
    while let data = try NativeMessageFraming.read(from: .standardInput) {
        let response = try host.receive(data)
        try NativeMessageFraming.write(JSONSerialization.data(withJSONObject: response), to: .standardOutput)
        if response["type"] == "stopped" { break }
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
