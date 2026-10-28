import Foundation
import CassiniKit

public struct BrowserProtocolError: LocalizedError {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

/// Native Messaging transport. Partial pipe reads are normal; bound before allocating.
public enum NativeMessageFraming {
    public static let maximumBytes = 512 * 1024

    public static func read(from handle: FileHandle) throws -> Data? {
        func exact(_ count: Int, allowEOF: Bool = false) throws -> Data? {
            var result = Data()
            while result.count < count {
                guard let part = try handle.read(upToCount: count - result.count), !part.isEmpty else {
                    if allowEOF && result.isEmpty { return nil }
                    throw BrowserProtocolError("framing", "Truncated native message.")
                }
                result.append(part)
            }
            return result
        }
        guard let header = try exact(4, allowEOF: true) else { return nil }
        let size = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard size > 0, size <= maximumBytes else { throw BrowserProtocolError("framing", "Native message is too large.") }
        return try exact(Int(size))
    }

    public static func write(_ data: Data, to handle: FileHandle) throws {
        guard data.count <= maximumBytes else { throw RecordingError.invalid("Native response is too large.") }
        var count = UInt32(data.count)
        try withUnsafeBytes(of: &count) { try handle.write(contentsOf: Data($0)) }
        try handle.write(contentsOf: data)
    }
}

public final class BrowserRecordingHost {
    public private(set) var session: RecordingSession?
    private let makeSession: (String) throws -> RecordingSession
    private var sequences: [String: Int] = [:]
    private var started = false
    private var stopped = false

    public convenience init(parent: URL) {
        self.init(makeSession:{ try RecordingSession(parent:parent,title:$0,source:"chromium") })
    }
    public init(makeSession: @escaping (String) throws -> RecordingSession) { self.makeSession = makeSession }

    public func receive(_ data: Data) throws -> [String: String] {
        let message: JSON
        do { message = try JSONParser.parse(data) }
        catch { throw BrowserProtocolError("framing", "Invalid JSON message.") }
        guard message.object != nil, let type = message["type"]?.string else { throw BrowserProtocolError("framing", "Expected a message object with a string type.") }
        func string(_ key: String, code: String) throws -> String? {
            guard let value = message[key], !value.isNull else { return nil }
            guard let text = value.string else { throw BrowserProtocolError(code, "\(key) must be a string.") }
            return text
        }
        func integer(_ key: String, code: String) throws -> Int? {
            guard let value = message[key], !value.isNull else { return nil }
            guard let number = value.int, abs(Double(number)) <= 9_007_199_254_740_991 else { throw BrowserProtocolError(code, "\(key) must be a safe integer literal.") }
            return number
        }
        func write(_ code: String, _ body: () throws -> Void) throws {
            do { try body() }
            catch let error as RecordingError {
                if case .limit = error { throw BrowserProtocolError("limit", error.localizedDescription) }
                throw BrowserProtocolError(code, error.localizedDescription)
            }
            catch { throw BrowserProtocolError("io", "Could not write the recording: \(error.localizedDescription)") }
        }
        switch type {
        case "start":
            guard !started else { throw BrowserProtocolError("state", "A recording has already started.") }
            let version = try integer("version", code: "version")
            guard version == nil || version == 1 else { throw BrowserProtocolError("version", "Unsupported browser recording protocol version.") }
            let title = try string("title", code: "source") ?? "Browser recording"
            try write("source") { session = try makeSession(title) }
            started = true
            return ["type": "started", "path": session!.directory.path]
        case "track":
            guard let session, !stopped else { throw BrowserProtocolError("state", "No active recording.") }
            guard let id = try string("id", code: "source"), let rate = try integer("sampleRate", code: "source"),
                  let channels = try integer("channels", code: "source"), let kind = try string("kind", code: "source") else {
                throw BrowserProtocolError("source", "Missing audio source information.")
            }
            let label = try string("label", code: "source") ?? kind
            guard session.manifest.tracks.count < 64 else { throw BrowserProtocolError("limit", "Too many audio sources.") }
            try write("source") { try session.addTrack(id: id, label: label, kind: kind, sampleRate: rate, channels: channels) }
            sequences[id] = 0
        case "audio":
            guard let session, !stopped else { throw BrowserProtocolError("state", "No active recording.") }
            guard let id = try string("id", code: "source"), sequences[id] != nil else { throw BrowserProtocolError("source", "Unknown audio source.") }
            guard let sequence = try integer("sequence", code: "sequence"), sequences[id] == sequence else { throw BrowserProtocolError("sequence", "Missing or out-of-order sequence.") }
            guard let encoded = try string("pcm", code: "chunk"), encoded.utf8.count <= 349_528,
                  let pcm = Data(base64Encoded: encoded), !pcm.isEmpty, pcm.count <= 262_144,
                  let offset = message["offsetMs"]?.double, offset.isFinite else { throw BrowserProtocolError("chunk", "Invalid audio samples or timestamp.") }
            try write("chunk") { try session.append(id: id, pcm: pcm, offsetMs: offset) }
            sequences[id] = sequence + 1
        case "stop":
            guard let session, !stopped else { throw BrowserProtocolError("state", "No active recording.") }
            let problem = try string("problem", code: "source")
            try write("io") { try session.finish(problem: problem) }
            stopped = true
            var response = ["type": "stopped", "path": session.directory.path]
            if let problem = session.manifest.problem { response["problem"] = problem }
            return response
        default: throw BrowserProtocolError("version", "Unknown browser message type.")
        }
        return ["type": "ack"]
    }

    public func disconnect(problem: String = "Browser disconnected before recording was stopped.") throws {
        if !stopped { try session?.finish(problem: problem); stopped = true }
    }
}
