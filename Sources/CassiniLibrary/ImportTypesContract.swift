// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin
import CassiniKit

/// Shared cross-platform audio import contract loaded from `Schema/import-types.json`
/// (`cassini-ux/import-types@1`). Consumes only `status == "decided"` entries (`opus-ogg`,
/// `mp3`, `m4a`, `wav`, `flac`), and enforces O(1) header
/// sniffing for ambiguous Ogg containers so Ogg video and FLAC-in-Ogg are rejected.
public struct ImportTypesContract: Sendable {
    public struct ContentValidation: Sendable, Equatable {
        public let minProbeBytes: Int
        public let containerMagic: Data
        public let acceptedBosMagics: [Data]
        public let secondPageMagic: Data
        public let rejectedBosMagics: [Data]
        public let ambiguousExtensions: [String]
        public let rejectedExtensions: [String]
        public let rejectedMimePrefixes: [String]
        public let rule: String
    }

    public struct HeaderValidation: Sendable, Equatable {
        public let minProbeBytes: Int
        public let magic: Data
        public let firstMetadataBlockType: Int
        public let streamInfoLength: Int
        public let rejectedMimeTypes: [String]
        public let rule: String
    }

    public struct TypeEntry: Sendable, Equatable {
        public let id: String
        public let label: String
        public let status: String
        public let extensions: [String]
        public let mimeTypes: [String]
        public let compatibilityMimeTypes: [String]
        public let utis: [String]
        public let androidMimeTypes: [String]
        public let decisions: [String]
        public let openTrackers: [String]
        public let contentValidation: ContentValidation?
        public let headerValidation: HeaderValidation?
        public let note: String

        public var bareExtensions: [String] {
            extensions.map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
        }
    }

    public struct ValidationResult: Sendable, Equatable {
        public let accepted: Bool
        public let typeID: String?
        public let reason: String

        public init(accepted: Bool, typeID: String?, reason: String) {
            self.accepted = accepted
            self.typeID = typeID
            self.reason = reason
        }
    }

    public enum ContractError: LocalizedError, Equatable, Sendable {
        case missingResource
        case invalidContract(String)
        case unsupportedCandidate(String)

        public var errorDescription: String? {
            LibraryLocalization.shared.text("mac.import.error.decodeFailed")
        }
    }

    public static let expectedSchema = "cassini-ux/import-types@1"
    public static let expectedPlatforms = ["gnome", "mac", "ios", "android"]

    public static let shared: ImportTypesContract = {
        do {
            return try loadBundled()
        } catch {
            preconditionFailure("Bundled import-types.json failed contract validation: \(error)")
        }
    }()

    public let rawBytes: Data
    public let sha256Hex: String
    public let schema: String
    public let version: String
    public let rule: String
    public let platforms: [String]
    public let entries: [TypeEntry]

    public var decidedEntries: [TypeEntry] {
        entries.filter { $0.status == "decided" }
    }

    public var openEntries: [TypeEntry] {
        entries.filter { $0.status == "open" }
    }

    /// Dotted extensions across `status == "decided"` entries (`[".opus", ".ogg", ".mp3", ".m4a", ".wav", ".flac"]`).
    public var decidedExtensions: [String] {
        decidedEntries.flatMap(\.extensions)
    }

    /// Bare lowercase extensions across `status == "decided"` entries (`["opus", "ogg", "mp3", "m4a", "wav", "flac"]`).
    public var decidedBareExtensions: [String] {
        decidedEntries.flatMap(\.bareExtensions)
    }

    public var decidedBareExtensionSet: Set<String> {
        Set(decidedBareExtensions)
    }

    /// UTIs across `status == "decided"` entries (never includes broad `public.audio`).
    public var decidedUTIIdentifiers: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in decidedEntries {
            for uti in entry.utis where seen.insert(uti).inserted {
                ordered.append(uti)
            }
        }
        return ordered
    }

    /// Safe subclass-aware picker MIME filters across `status == "decided"` entries (excludes `compatibilityMimeTypes`).
    public var pickerMimeTypes: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in decidedEntries {
            for mime in entry.mimeTypes where seen.insert(mime).inserted {
                ordered.append(mime)
            }
        }
        return ordered
    }

    /// Minimum header probe byte count needed across all content and header validation entries (`1024`).
    public var maxProbeBytes: Int {
        decidedEntries.flatMap { [$0.contentValidation?.minProbeBytes, $0.headerValidation?.minProbeBytes].compactMap { $0 } }.max() ?? 1024
    }

    public static func loadBundled() throws -> ImportTypesContract {
        guard let url = Bundle.module.url(forResource: "import-types", withExtension: "json", subdirectory: "Schema")
            ?? Bundle.module.url(forResource: "import-types", withExtension: "json") else {
            throw ContractError.missingResource
        }
        return try load(from: url)
    }

    public static func load(from url: URL) throws -> ImportTypesContract {
        let data = try Data(contentsOf: url)
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> ImportTypesContract {
        let root: JSON
        do {
            root = try JSONParser.parse(data)
        } catch {
            throw ContractError.invalidContract("strict JSON parse failed: \(error)")
        }
        guard let obj = root.object else {
            throw ContractError.invalidContract("top-level value must be a JSON object")
        }
        guard root["schema"]?.string == expectedSchema else {
            throw ContractError.invalidContract("schema must equal \(expectedSchema)")
        }
        guard let version = root["version"]?.string,
              version.range(of: #"^\d{4}-\d{2}-\d{2}\.\d+$"#, options: .regularExpression) != nil else {
            throw ContractError.invalidContract("version must match YYYY-MM-DD.N")
        }
        guard root["source"]?.object != nil else {
            throw ContractError.invalidContract("source must be a JSON object")
        }
        guard let rule = root["rule"]?.string, !rule.isEmpty else {
            throw ContractError.invalidContract("rule must be a non-empty string")
        }
        let platforms = try requireStringList(root["platforms"], where: "platforms")
        guard platforms == expectedPlatforms else {
            throw ContractError.invalidContract("platforms must equal \(expectedPlatforms)")
        }
        guard let rawTypes = root["types"]?.array, !rawTypes.isEmpty else {
            throw ContractError.invalidContract("types must be a non-empty array")
        }
        let knownTopKeys: Set<String> = ["schema", "version", "source", "platforms", "rule", "types"]
        for (key, _) in obj where !knownTopKeys.contains(key) {
            throw ContractError.invalidContract("unknown top-level key \(key)")
        }

        var parsedEntries: [TypeEntry] = []
        var seenIDs = Set<String>()
        var seenExtensions = Set<String>()

        for (index, item) in rawTypes.enumerated() {
            let loc = "types[\(index)]"
            guard item.object != nil else {
                throw ContractError.invalidContract("\(loc) must be an object")
            }
            guard let id = item["id"]?.string, !id.isEmpty, seenIDs.insert(id).inserted else {
                throw ContractError.invalidContract("\(loc): missing or duplicate id")
            }
            guard let label = item["label"]?.string, !label.isEmpty else {
                throw ContractError.invalidContract("\(loc): missing label")
            }
            guard let status = item["status"]?.string, status == "decided" || status == "open" else {
                throw ContractError.invalidContract("\(loc): status must be 'decided' or 'open'")
            }
            let extensions = try requireStringList(item["extensions"], where: "\(loc).extensions")
            for ext in extensions {
                guard ext.hasPrefix("."), ext.count >= 2, ext == ext.lowercased() else {
                    throw ContractError.invalidContract("\(loc): invalid extension \(ext)")
                }
                guard seenExtensions.insert(ext).inserted else {
                    throw ContractError.invalidContract("\(loc): duplicate extension \(ext)")
                }
            }
            let mimeTypes = try requireStringList(item["mimeTypes"], where: "\(loc).mimeTypes")
            let compatMimes = try requireStringList(item["compatibilityMimeTypes"], where: "\(loc).compatibilityMimeTypes", allowEmpty: true)
            let utis = try requireStringList(item["utis"], where: "\(loc).utis")
            let androidMimeTypes = try requireStringList(item["androidMimeTypes"], where: "\(loc).androidMimeTypes")
            guard let note = item["note"]?.string, !note.isEmpty else {
                throw ContractError.invalidContract("\(loc): missing note")
            }
            let bannedUTIs: Set<String> = ["public.audio", "public.audiovisual-content", "public.movie", "public.data", "public.content", "public.item"]
            for uti in utis where bannedUTIs.contains(uti) {
                throw ContractError.invalidContract("\(loc): UTI \(uti) is too broad")
            }

            let decisions: [String]
            let openTrackers: [String]
            if status == "decided" {
                decisions = try requireStringList(item["decisions"], where: "\(loc).decisions")
                if item["open"] != nil {
                    throw ContractError.invalidContract("\(loc): decided entry cannot contain 'open'")
                }
                openTrackers = []
            } else {
                openTrackers = try requireStringList(item["open"], where: "\(loc).open")
                if item["decisions"] != nil {
                    throw ContractError.invalidContract("\(loc): open entry cannot contain 'decisions'")
                }
                decisions = []
            }

            let contentValidation: ContentValidation?
            if let cvJSON = item["contentValidation"] {
                contentValidation = try parseContentValidation(cvJSON, entryExtensions: extensions, where: "\(loc).contentValidation")
            } else {
                contentValidation = nil
            }

            let headerValidation: HeaderValidation?
            if let hv = item["headerValidation"] {
                guard contentValidation == nil, compatMimes.isEmpty, id == "flac",
                      let minProbe = hv["minProbeBytes"]?.int, (42...65536).contains(minProbe),
                      hv["magicHex"]?.string == "664c6143",
                      hv["firstMetadataBlockType"]?.int == 0,
                      hv["streamInfoLength"]?.int == 34,
                      let rule = hv["rule"]?.string, !rule.isEmpty else {
                    throw ContractError.invalidContract("\(loc).headerValidation invalid native FLAC rule")
                }
                let rejected = try requireStringList(hv["rejectedMimeTypes"], where: "\(loc).headerValidation.rejectedMimeTypes")
                guard Set(["audio/x-flac+ogg", "audio/x-oggflac", "audio/ogg", "application/ogg"]).isSubset(of: Set(rejected)),
                      Set(rejected).isDisjoint(with: mimeTypes) else {
                    throw ContractError.invalidContract("\(loc).headerValidation invalid rejected MIME types")
                }
                headerValidation = HeaderValidation(minProbeBytes: minProbe, magic: Data("fLaC".utf8),
                    firstMetadataBlockType: 0, streamInfoLength: 34, rejectedMimeTypes: rejected, rule: rule)
            } else {
                guard id != "flac" || status != "decided" else {
                    throw ContractError.invalidContract("\(loc) requires headerValidation")
                }
                headerValidation = nil
            }

            parsedEntries.append(TypeEntry(
                id: id,
                label: label,
                status: status,
                extensions: extensions,
                mimeTypes: mimeTypes,
                compatibilityMimeTypes: compatMimes,
                utis: utis,
                androidMimeTypes: androidMimeTypes,
                decisions: decisions,
                openTrackers: openTrackers,
                contentValidation: contentValidation,
                headerValidation: headerValidation,
                note: note
            ))
        }

        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ImportTypesContract(
            rawBytes: data,
            sha256Hex: sha,
            schema: expectedSchema,
            version: version,
            rule: rule,
            platforms: platforms,
            entries: parsedEntries
        )
    }

    private static func parseContentValidation(
        _ cv: JSON,
        entryExtensions: [String],
        where loc: String
    ) throws -> ContentValidation {
        guard cv.object != nil else {
            throw ContractError.invalidContract("\(loc) must be an object")
        }
        guard let minProbeBytes = cv["minProbeBytes"]?.int, (64...65536).contains(minProbeBytes) else {
            throw ContractError.invalidContract("\(loc).minProbeBytes out of range")
        }
        guard let containerHex = cv["containerMagicHex"]?.string, let containerMagic = Data(hexString: containerHex), !containerMagic.isEmpty else {
            throw ContractError.invalidContract("\(loc).containerMagicHex invalid")
        }
        let acceptedHexes = try requireStringList(cv["acceptedBosMagicHex"], where: "\(loc).acceptedBosMagicHex")
        let acceptedMagics = try acceptedHexes.map { hex -> Data in
            guard let bytes = Data(hexString: hex), !bytes.isEmpty else {
                throw ContractError.invalidContract("\(loc).acceptedBosMagicHex invalid hex \(hex)")
            }
            return bytes
        }
        guard let secondHex = cv["secondPageMagicHex"]?.string, let secondPageMagic = Data(hexString: secondHex), !secondPageMagic.isEmpty else {
            throw ContractError.invalidContract("\(loc).secondPageMagicHex invalid")
        }
        let rejectedHexes = try requireStringList(cv["rejectedBosMagicHex"], where: "\(loc).rejectedBosMagicHex")
        let rejectedMagics = try rejectedHexes.map { hex -> Data in
            guard let bytes = Data(hexString: hex), !bytes.isEmpty else {
                throw ContractError.invalidContract("\(loc).rejectedBosMagicHex invalid hex \(hex)")
            }
            return bytes
        }
        let ambiguousExts = try requireStringList(cv["ambiguousExtensions"], where: "\(loc).ambiguousExtensions")
        for ext in ambiguousExts where !entryExtensions.contains(ext) {
            throw ContractError.invalidContract("\(loc): ambiguous extension \(ext) not in entry extensions")
        }
        let rejectedExts = try requireStringList(cv["rejectedExtensions"], where: "\(loc).rejectedExtensions")
        let rejectedPrefixes = try requireStringList(cv["rejectedMimePrefixes"], where: "\(loc).rejectedMimePrefixes")
        guard let rule = cv["rule"]?.string, !rule.isEmpty else {
            throw ContractError.invalidContract("\(loc).rule must be a non-empty string")
        }
        return ContentValidation(
            minProbeBytes: minProbeBytes,
            containerMagic: containerMagic,
            acceptedBosMagics: acceptedMagics,
            secondPageMagic: secondPageMagic,
            rejectedBosMagics: rejectedMagics,
            ambiguousExtensions: ambiguousExts,
            rejectedExtensions: rejectedExts,
            rejectedMimePrefixes: rejectedPrefixes,
            rule: rule
        )
    }

    private static func requireStringList(_ json: JSON?, where loc: String, allowEmpty: Bool = false) throws -> [String] {
        guard let array = json?.array, (allowEmpty || !array.isEmpty) else {
            throw ContractError.invalidContract("\(loc) must be a \(allowEmpty ? "" : "non-empty ")string array")
        }
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(array.count)
        for item in array {
            guard let str = item.string, !str.isEmpty, seen.insert(str).inserted else {
                throw ContractError.invalidContract("\(loc) contains invalid or duplicate string")
            }
            result.append(str)
        }
        return result
    }

    // MARK: - Candidate & Header Validation

    private static func canonicalMime(_ mime: String) -> String {
        switch mime {
        case "audio/mp3", "audio/x-mp3", "audio/x-mpg", "audio/x-mpeg": return "audio/mpeg"
        case "audio/x-m4a", "audio/m4a": return "audio/mp4"
        case "audio/wav", "audio/x-wav", "audio/wave": return "audio/vnd.wave"
        case "audio/opus": return "audio/x-opus+ogg"
        case "audio/x-flac": return "audio/flac"
        case "audio/x-oggflac": return "audio/x-flac+ogg"
        case "audio/vorbis", "audio/x-vorbis": return "audio/x-vorbis+ogg"
        case "audio/speex": return "audio/x-speex+ogg"
        default: return mime
        }
    }

    /// Extracts the lowercase dotted extension (`".opus"`) from `fileName`, returning `""` for
    /// dotfiles with no stem (`".opus"`) or extensionless basenames (`"README"`).
    public static func dottedExtension(for fileName: String) -> String {
        let base = fileName.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? fileName
        guard let dot = base.lastIndex(of: "."), dot > base.startIndex else {
            return ""
        }
        let ext = String(base[dot...]).lowercased()
        return ext.count >= 2 ? ext : ""
    }

    /// Validates a candidate filename, optional MIME type, and optional leading file bytes against
    /// `decided` types, rejecting `open` types, `video/*`, `.oga`/`.ogv`/`.ogx`, and
    /// non-Opus or multiplexed Ogg streams.
    public func validateCandidate(
        fileName: String,
        mimeType: String? = nil,
        headerBytes: Data? = nil
    ) -> ValidationResult {
        let ext = Self.dottedExtension(for: fileName)

        var decidedByExt: [String: TypeEntry] = [:]
        for entry in decidedEntries {
            for itemExt in entry.extensions {
                decidedByExt[itemExt] = entry
            }
        }

        var openByExt: [String: String] = [:]
        var openMimes = Set<String>()
        for entry in openEntries {
            for itemExt in entry.extensions {
                openByExt[itemExt] = entry.id
            }
            for m in entry.mimeTypes {
                openMimes.insert(m)
                openMimes.insert(Self.canonicalMime(m))
            }
        }

        let baseMime: String?
        if let rawMime = mimeType?.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first {
            let trimmed = rawMime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            baseMime = trimmed.isEmpty ? nil : trimmed
        } else {
            baseMime = nil
        }

        if let baseMime {
            if baseMime.hasPrefix("video/") {
                return ValidationResult(accepted: false, typeID: nil, reason: "rejected video MIME type '\(baseMime)'")
            }
            if openMimes.contains(baseMime) || openMimes.contains(Self.canonicalMime(baseMime)) {
                return ValidationResult(accepted: false, typeID: nil, reason: "rejected open MIME type '\(baseMime)'")
            }
        }

        if let openID = openByExt[ext] {
            return ValidationResult(accepted: false, typeID: nil, reason: "rejected extension '\(ext)' belonging to open type '\(openID)'")
        }

        guard let entry = decidedByExt[ext] else {
            return ValidationResult(accepted: false, typeID: nil, reason: "unsupported extension '\(ext)'")
        }

        if let cv = entry.contentValidation {
            if cv.rejectedExtensions.contains(ext) {
                return ValidationResult(accepted: false, typeID: nil, reason: "rejected extension '\(ext)'")
            }
            if let baseMime {
                for prefix in cv.rejectedMimePrefixes where baseMime.hasPrefix(prefix) {
                    return ValidationResult(accepted: false, typeID: nil, reason: "rejected MIME prefix '\(prefix)' ('\(baseMime)')")
                }
            }
        }

        let safeMimes = Set(entry.mimeTypes)
        let compatMimes = Set(entry.compatibilityMimeTypes)
        if let baseMime, !safeMimes.contains(baseMime), !compatMimes.contains(baseMime) {
            return ValidationResult(accepted: false, typeID: nil, reason: "MIME type '\(baseMime)' is not accepted for '\(entry.id)'")
        }

        if let hv = entry.headerValidation {
            guard let headerBytes else {
                return ValidationResult(accepted: false, typeID: nil, reason: "header validation required for '\(entry.id)'")
            }
            let bytes = [UInt8](headerBytes)
            guard !hv.rejectedMimeTypes.contains(baseMime ?? ""),
                  bytes.count >= hv.minProbeBytes,
                  headerBytes.starts(with: hv.magic),
                  Int(bytes[4] & 0x7f) == hv.firstMetadataBlockType,
                  (Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])) == hv.streamInfoLength,
                  (Int(bytes[18]) << 12 | Int(bytes[19]) << 4 | Int(bytes[20]) >> 4) != 0 else {
                return ValidationResult(accepted: false, typeID: nil, reason: "invalid native FLAC STREAMINFO header")
            }
        }

        if let cv = entry.contentValidation {
            let needsSniff = cv.ambiguousExtensions.contains(ext) || baseMime == nil || (baseMime.map(compatMimes.contains) ?? false)
            if needsSniff && headerBytes == nil {
                return ValidationResult(accepted: false, typeID: nil, reason: "content validation required for ambiguous '\(entry.id)' input (\(ext))")
            }
            if let headerBytes {
                let (ok, detail) = Self.inspectOggOpusBOS(headerBytes, contentValidation: cv)
                if !ok {
                    return ValidationResult(accepted: false, typeID: nil, reason: "content validation failed for '\(entry.id)': \(detail)")
                }
            }
        } else if entry.headerValidation == nil, let headerBytes {
            if headerBytes.starts(with: Data("fLaC".utf8)) {
                return ValidationResult(accepted: false, typeID: nil, reason: "native FLAC stream disguised as '\(ext)'")
            }
            if headerBytes.starts(with: Data("OggS".utf8)) {
                return ValidationResult(accepted: false, typeID: nil, reason: "Ogg container disguised as '\(ext)'")
            }
        }

        return ValidationResult(accepted: true, typeID: entry.id, reason: "accepted")
    }

    /// Reads up to `maxProbeBytes` (`1024`) from `url` without following symlinks and validates the candidate.
    public func validateFile(at url: URL, fileNameOverride: String? = nil, mimeType: String? = nil) -> ValidationResult {
        let candidateName = fileNameOverride ?? url.lastPathComponent
        let ext = Self.dottedExtension(for: candidateName)
        guard decidedEntries.contains(where: { $0.extensions.contains(ext) }) else {
            return validateCandidate(fileName: candidateName, mimeType: mimeType, headerBytes: nil)
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            return ValidationResult(accepted: false, typeID: nil, reason: "unable to open file for header probe")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0 else {
            return ValidationResult(accepted: false, typeID: nil, reason: "not a non-empty regular file")
        }
        let probeLimit = maxProbeBytes
        var probe = Data(count: probeLimit)
        let bytesRead: Int = probe.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            var total = 0
            while total < probeLimit {
                let n = Darwin.read(fd, base.advanced(by: total), probeLimit - total)
                if n < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                if n == 0 { break }
                total += n
            }
            return total
        }
        guard bytesRead > 0 else {
            return ValidationResult(accepted: false, typeID: nil, reason: "empty or unreadable header probe")
        }
        probe.removeSubrange(bytesRead..<probe.count)
        return validateCandidate(fileName: candidateName, mimeType: mimeType, headerBytes: probe)
    }

    /// Returns `true` when `url` is readable and its leading header bytes identify a known
    /// unsupported container/codec (such as native `fLaC` under another extension, Ogg video Theora/OGM/Dirac/Daala/Skeleton,
    /// multiplexed Ogg BOS streams, FLAC-in-Ogg, Ogg Vorbis/Speex, or QuickTime `.mov`) disguised
    /// under a decided extension. Damaged/corrupt files of a decided extension return `false` so
    /// dropping them transitions from `Importing…` into the `Needs attention` card (`W4.6`).
    public func isDisguisedUnsupportedContainer(at url: URL) -> Bool {
        let ext = Self.dottedExtension(for: url.lastPathComponent)
        guard decidedEntries.contains(where: { $0.extensions.contains(ext) }) else {
            return true
        }
        // Let every .flac reach authoritative import validation, including malformed or
        // disguised streams, so failed drops retain the Needs attention card (D102).
        if decidedEntries.contains(where: { $0.extensions.contains(ext) && $0.headerValidation != nil }) {
            return false
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size > 0,
              (st.st_flags & UInt32(SF_DATALESS)) == 0 else {
            return false
        }
        var fs = statfs()
        if fstatfs(fd, &fs) == 0, (fs.f_flags & UInt32(MNT_LOCAL)) == 0 {
            return false
        }
        let probeLimit = maxProbeBytes
        var probe = Data(count: probeLimit)
        let bytesRead: Int = probe.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            var total = 0
            while total < probeLimit {
                let n = Darwin.read(fd, base.advanced(by: total), probeLimit - total)
                if n < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                if n == 0 { break }
                total += n
            }
            return total
        }
        guard bytesRead >= 4 else { return false }
        probe.removeSubrange(bytesRead..<probe.count)
        let bytes = [UInt8](probe)

        // Native FLAC is accepted only under its own .flac extension.
        if bytes.starts(with: [0x66, 0x4C, 0x61, 0x43]) {
            return true
        }
        if let entry = decidedEntries.first(where: { $0.extensions.contains(ext) }),
           let cv = entry.contentValidation {
            let containerMagic = [UInt8](cv.containerMagic)
            if bytes.count >= 28, bytes.starts(with: containerMagic), bytes[4] == 0 {
                let pageSegments = Int(bytes[26])
                let segTableEnd = 27 + pageSegments
                if bytes.count >= segTableEnd {
                    var payloadLen = 0
                    for i in 27..<segTableEnd { payloadLen += Int(bytes[i]) }
                    let page0End = segTableEnd + payloadLen
                    if payloadLen > 0, bytes.count >= page0End {
                        let bosPayload = Array(bytes[segTableEnd..<page0End])
                        for badData in cv.rejectedBosMagics where bosPayload.starts(with: [UInt8](badData)) {
                            return true
                        }
                        if !cv.acceptedBosMagics.contains(where: { bosPayload.starts(with: [UInt8]($0)) }) {
                            return true
                        }
                        if bytes.count >= page0End + 28,
                           Array(bytes[page0End..<(page0End + containerMagic.count)]) == containerMagic,
                           (bytes[page0End + 5] & 0x02) != 0 {
                            return true
                        }
                    }
                }
            }
        } else {
            // Non-Ogg decided types (`.mp3`, `.m4a`, `.wav`) must not wrap an Ogg container or QuickTime `.mov`.
            if bytes.starts(with: [0x4F, 0x67, 0x67, 0x53]) {
                return true
            }
            if ext == ".m4a", bytes.count >= 12,
               Array(bytes[4..<8]) == Array("ftyp".utf8),
               Array(bytes[8..<12]) == Array("qt  ".utf8) {
                return true
            }
        }
        return false
    }

    /// Verifies in O(1) that `headerBytes` begins with an unmultiplexed RFC 7845 Ogg Opus BOS page
    /// followed immediately by an `OpusTags` comment header page.
    public static func inspectOggOpusBOS(_ headerBytes: Data, contentValidation: ContentValidation) -> (Bool, String) {
        let bytes = [UInt8](headerBytes)
        if bytes.starts(with: [0x66, 0x4C, 0x61, 0x43]) { // "fLaC"
            return (false, "native FLAC stream (fLaC), not Ogg Opus")
        }
        let containerMagic = [UInt8](contentValidation.containerMagic)
        guard bytes.count >= 28, bytes.starts(with: containerMagic) else {
            return (false, "missing OggS container capture pattern")
        }
        guard bytes[4] == 0 else {
            return (false, "unsupported Ogg stream_structure_version \(bytes[4])")
        }
        let headerType = bytes[5]
        if (headerType & 0x02) == 0 || (headerType & 0x01) != 0 {
            return (false, "first Ogg page is not a fresh Beginning-of-Stream (BOS) page")
        }
        let pageSegments = Int(bytes[26])
        let segTableEnd = 27 + pageSegments
        guard bytes.count >= segTableEnd else {
            return (false, "truncated Ogg page segment table")
        }
        var payloadLen = 0
        for i in 27..<segTableEnd {
            payloadLen += Int(bytes[i])
        }
        let page0End = segTableEnd + payloadLen
        guard payloadLen > 0, bytes.count >= page0End else {
            return (false, "truncated or empty Ogg BOS payload")
        }
        let bosPayload = Array(bytes[segTableEnd..<page0End])

        for badData in contentValidation.rejectedBosMagics {
            let badMagic = [UInt8](badData)
            if bosPayload.starts(with: badMagic) {
                if badMagic == [0x7F, 0x46, 0x4C, 0x41, 0x43] {
                    return (false, "undecided FLAC-in-Ogg stream")
                }
                return (false, "unsupported Ogg codec BOS stream")
            }
        }

        let matchesAccepted = contentValidation.acceptedBosMagics.contains { okData in
            bosPayload.starts(with: [UInt8](okData))
        }
        guard matchesAccepted else {
            return (false, "unrecognized non-Opus Ogg BOS stream")
        }
        if bosPayload.starts(with: Array("OpusHead".utf8)) {
            guard bosPayload.count >= 19 else {
                return (false, "truncated OpusHead identification header (< 19 bytes)")
            }
            guard (bosPayload[8] & 0xF0) == 0 else {
                return (false, "unsupported OpusHead major version in byte \(bosPayload[8])")
            }
        }

        if (headerType & 0x04) != 0 {
            return (false, "first Ogg page prematurely ends stream before OpusTags page")
        }
        guard bytes.count >= page0End + 28,
              Array(bytes[page0End..<(page0End + containerMagic.count)]) == containerMagic else {
            return (false, "missing or corrupt second Ogg page header")
        }
        guard bytes[page0End + 4] == 0 else {
            return (false, "unsupported second Ogg page version \(bytes[page0End + 4])")
        }
        let nextHeaderType = bytes[page0End + 5]
        if (nextHeaderType & 0x02) != 0 {
            return (false, "multiplexed Ogg container with multiple concurrent BOS streams")
        }
        if (nextHeaderType & 0x01) != 0 {
            return (false, "unexpected continued packet on second Ogg page")
        }
        let nextSegments = Int(bytes[page0End + 26])
        let nextPayloadStart = page0End + 27 + nextSegments
        let secondMagic = [UInt8](contentValidation.secondPageMagic)
        guard bytes.count >= nextPayloadStart + secondMagic.count else {
            return (false, "truncated second Ogg page before OpusTags magic")
        }
        guard Array(bytes[nextPayloadStart..<(nextPayloadStart + secondMagic.count)]) == secondMagic else {
            return (false, "second Ogg page does not begin with OpusTags comment header")
        }
        return (true, "opus")
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var idx = hexString.startIndex
        while idx < hexString.endIndex {
            let next = hexString.index(idx, offsetBy: 2)
            guard let byte = UInt8(hexString[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        self.init(bytes)
    }
}
