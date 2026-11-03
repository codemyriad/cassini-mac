// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D58 (R79) session `refusals`: a side that was requested but never opened, at start or at a
/// later turn-on. A side opened once its first buffer was admitted; before that, any failure is
/// a refusal, after it nothing is. Refusals never change state, problem, problemKind, the end
/// reason, othersSource or captureOutcome.
public struct CaptureRefusal: Codable, Sendable, Equatable {
    public static let limit = 16
    public static let maximumAtMs: Double = 86_460_000
    /// Codes a writer uses. `startFailed` is banner-only and never stored.
    public static let permissionDenied = "permissionDenied", deviceUnavailable = "deviceUnavailable"
    public static let startRejected = "startRejected", startFailed = "startFailed"

    public let atMs: Double
    public let side: String
    public let code: String
    public let detail: String?
    public let message: String?

    /// A writer's entry: a detail is kept only when it is a whole-string token; the message is
    /// raw text cut to its first 200 code points, and an empty one is omitted.
    public init?(atMs: Double, side: String, code: String, detail: String? = nil, message: String? = nil) {
        guard atMs.isFinite, (0...Self.maximumAtMs).contains(atMs), Self.isToken(side), Self.isToken(code) else { return nil }
        self.atMs = atMs; self.side = side; self.code = code
        self.detail = detail.flatMap { Self.isToken($0) ? $0 : nil }
        self.message = message.flatMap { $0.isEmpty ? nil : Self.cut($0) }
    }

    /// `^[A-Za-z]{1,32}$` applied to the whole string: "busy\n" is not a token.
    public static func isToken(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        return (1...32).contains(scalars.count) && scalars.allSatisfy { ("A"..."Z").contains($0) || ("a"..."z").contains($0) }
    }
    /// The first 200 Unicode code points (not bytes, UTF-16 units or graphemes).
    public static func cut(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.prefix(200)))
    }
    /// In the order things happened, at most 16: a newer refusal replaces the 16th entry, so the
    /// list keeps the first 15 plus the latest.
    public static func appending(_ refusal: CaptureRefusal, to list: [CaptureRefusal]) -> [CaptureRefusal] {
        var list = list
        if list.count < limit { list.append(refusal) } else { list[limit-1] = refusal }
        return list
    }
    /// A browser Start answered `ok:false` (SPEC-CONTROL "Result codes"): a pattern-valid result
    /// code becomes the detail, the error the message.
    public static func startRejected(atMs: Double, code: String?, error: String?) -> CaptureRefusal? {
        .init(atMs:atMs,side:"browser",code:startRejected,detail:code,message:error)
    }

    enum CodingKeys: String, CodingKey { case atMs, side, code, detail, message }
    /// Readers skip an entry the session schema's item rejects; null detail/message mean absent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        let atMs = try c.decode(Double.self,forKey:.atMs), side = try c.decode(String.self,forKey:.side), code = try c.decode(String.self,forKey:.code)
        let detail = try c.decodeIfPresent(String.self,forKey:.detail), message = try c.decodeIfPresent(String.self,forKey:.message)
        guard atMs.isFinite, (0...Self.maximumAtMs).contains(atMs), Self.isToken(side), Self.isToken(code),
              detail.map(Self.isToken) ?? true, message.map({ $0.unicodeScalars.count <= 200 }) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath,debugDescription:"Malformed refusal."))
        }
        self.atMs = atMs; self.side = side; self.code = code; self.detail = detail; self.message = message
    }
    /// A list member that is not a list is ignored as a whole; a malformed entry is skipped.
    struct Lossy: Decodable {
        let value: CaptureRefusal?
        init(from decoder: Decoder) throws { value = try? CaptureRefusal(from:decoder) }
    }
}

/// Why a native side failed to open, for its refusal (D58). Only an OS-reported denial is
/// `permissionDenied`; never inferred from silence. The message is raw text, never catalog copy.
public struct CaptureOpenRefusal: Error, Sendable, Equatable {
    public let code: String
    public let message: String?
    public init(code: String, message: String? = nil) { self.code = code; self.message = message }
    public static let denied = CaptureOpenRefusal(code:CaptureRefusal.permissionDenied)
    /// No first buffer within the 3 s bound.
    public static let noSample = CaptureOpenRefusal(code:CaptureRefusal.deviceUnavailable,message:"No audio buffer within 3 s.")
    /// The NSError user-info key a driver sets for raw OS text, such as `AudioHardwareCreateProcessTap: -50`.
    public static let rawTextKey = "CassiniRawRefusalText"
    public static func classify(_ error: Error) -> CaptureOpenRefusal {
        if let refusal = error as? CaptureOpenRefusal { return refusal }
        // RecordingError text can be catalog copy: no message.
        if error is RecordingError { return .init(code:CaptureRefusal.deviceUnavailable) }
        let ns = error as NSError
        if let raw = ns.userInfo[rawTextKey] as? String { return .init(code:CaptureRefusal.deviceUnavailable,message:raw) }
        // A system error's domain and code, or a Swift error's case: raw, never localized copy.
        if type(of:error) is NSError.Type { return .init(code:CaptureRefusal.deviceUnavailable,message:ns.domain+" "+String(ns.code)) }
        return .init(code:CaptureRefusal.deviceUnavailable,message:String(describing:error))
    }
}

extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
