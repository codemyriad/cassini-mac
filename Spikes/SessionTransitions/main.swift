// SPDX-License-Identifier: GPL-3.0-or-later
// Build-only persistence fault probe. Generated files only; no device or app UI.
import Foundation
import Darwin
import CassiniKit
@_spi(Testing) import CassiniRecording

do {
    guard CommandLine.arguments.count == 3, let phase = RecordingCheckpointPhase(rawValue:CommandLine.arguments[2]) else { exit(2) }
    let root = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
    var info = stat()
    guard root.lastPathComponent.hasPrefix("CassiniCaptureCrash-"), lstat(root.path,&info) == 0,
          info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { exit(2) }
    alarm(10) // A dead test parent cannot leave a paused fixture process behind.
    let session = try RecordingSession(parent:root,title:"Generated persistence fixture",source:"chromium")
    try session.transition(starting:[.init(id:"remote",label:"Generated",kind:"remote",sampleRate:8000,channels:1)],events:[.init(atMs:0,type:"othersSource",source:"browser",reason:"start"),.init(atMs:0,type:"selection",reason:"start",me:true,others:true)])
    try session.append(id:"remote",pcm:Data(repeating:0,count:16000),offsetMs:0)
    try Data(contentsOf:session.directory.appendingPathComponent("session.json")).write(to:root.appendingPathComponent("before.json"))
    session.checkpointObserver = { reached in
        if reached == phase {
            let message = try! JSONSerialization.data(withJSONObject:["path":session.directory.path,"phase":phase.rawValue]) + Data([10])
            try! FileHandle.standardOutput.write(contentsOf:message)
            while true { pause() } // The owning XCTest sends SIGKILL at this exact boundary.
        }
    }
    try session.transition(starting:[.init(id:"system",label:"Generated system",kind:"system",sampleRate:8000,channels:1,labelSource:"device")],ending:["remote"],events:[.init(atMs:1000,type:"othersSource",source:"system",reason:"lost")])
    exit(3) // The requested phase must have been reached before this point.
} catch {
    try? FileHandle.standardError.write(contentsOf:Data((String(describing:error)+"\n").utf8)); exit(1)
}
