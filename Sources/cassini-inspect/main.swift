import CassiniKit
import Foundation

// Prints one conformance-suite observation for a file (spec/conformance adapter protocol),
// or, with --summary, a short human-readable report.

let args = CommandLine.arguments.dropFirst()
guard let path = args.first(where: { !$0.hasPrefix("--") }) else {
    FileHandle.standardError.write(Data("usage: cassini-inspect [--metadata] [--summary] FILE.opus\n".utf8))
    exit(64)
}
let verifyAudio = !args.contains("--metadata")

func findings(_ list: [Finding]) -> [[String: String]] {
    list.map { f in
        var o = ["code": f.code, "message": f.message]
        if let t = f.tag { o["tag"] = t }
        return o
    }
}

var obs: [String: Any] = ["reader": "cassini-mac CassiniKit", "profile": verifyAudio ? "full" : "metadata"]
do {
    let file = try CassiniReader.read(contentsOf: URL(fileURLWithPath: path), verifyAudio: verifyAudio)
    if args.contains("--summary") {
        print("state: \(file.state.rawValue)")
        if let r = file.stateReason { print("reason: \(r)") }
        if let m = file.manifest {
            print("title: \(m.meeting.title)")
            print("speakers: \(m.speakers.map(\.label).joined(separator: ", "))")
            for (e, load) in file.transcripts {
                print("transcript \(e.id)\(e.id == m.defaultTranscript?.id ? " (default)" : ""): "
                    + (load.transcript.map { "\($0.items.count) words" } ?? "unavailable"))
            }
        }
        for f in file.errors { print("error: \(f.code) \(f.tag ?? "") \(f.message)") }
        for f in file.warnings { print("warning: \(f.code) \(f.tag ?? "") \(f.message)") }
        exit(0)
    }
    obs["state"] = file.state.rawValue
    switch file.state {
    case .plainAudio: obs["classification"] = "plain-audio"
    case .unknownCassiniFormat: obs["classification"] = "unsupported-version"
    case .invalidCassiniMetadata: obs["classification"] = "damaged-metadata"
    default: obs["classification"] = "cassini"
    }
    switch file.state {
    case .plainAudio: obs["payloadTrust"] = "not-applicable"
    case .unknownCassiniFormat: obs["payloadTrust"] = "unverified"
    case .invalidCassiniMetadata:
        obs["payloadTrust"] = file.errors.contains { $0.code == "payload-sha256-mismatch" && $0.tag == "CASSINI_PAYLOAD_SHA256" }
            ? "mismatched" : "unverified"
    default: obs["payloadTrust"] = "verified"
    }
    switch file.audioCheck {
    case .notApplicable: obs["audioTrust"] = file.state == .plainAudio ? "not-applicable" : (verifyAudio ? "unverified" : "not-checked")
    case .notChecked: obs["audioTrust"] = "not-checked"
    case .verified: obs["audioTrust"] = "verified"
    case .mismatched: obs["audioTrust"] = "mismatched"
    case .unverifiable: obs["audioTrust"] = "unverified"
    }
    if case .success(let d)? = file.audioDigest { obs["audioOpusSha256"] = d.sha256 }
    if let id = file.formatId { obs["formatId"] = id }
    if let m = file.manifest {
        obs["manifestVersion"] = m.version
        obs["manifestKind"] = m.raw["kind"]?.string
        obs["transcriptIds"] = m.transcripts.map(\.id)
        obs["defaultTranscriptId"] = m.defaultTranscript?.id
        obs["speakerIds"] = m.speakers.map(\.id)
        var counts: [String: Int] = [:]
        for (e, load) in file.transcripts { if let t = load.transcript { counts[e.id] = t.items.count } }
        obs["wordCounts"] = counts
    }
    obs["errors"] = findings(file.errors)
    obs["warnings"] = findings(file.warnings)
} catch {
    obs["state"] = "invalid-cassini-metadata"
    obs["classification"] = "damaged-metadata"
    obs["payloadTrust"] = "unverified"
    obs["audioTrust"] = "not-checked"
    obs["errors"] = [["code": "not-opus", "message": "\(error)"]]
    obs["warnings"] = [[String: String]]()
}
let out = try JSONSerialization.data(withJSONObject: obs, options: [.sortedKeys])
print(String(decoding: out, as: UTF8.self))
