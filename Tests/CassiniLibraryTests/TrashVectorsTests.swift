// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Testing
import CassiniKit
@testable import CassiniLibrary

/// S-12 §7.1 conformance suite: runs all 30 shared cases, every crashMatrix[k] point,
/// all invariants, and all 8 daysLeft vectors from Golden/library-v2/trash-vectors.json
/// against LibraryTrash on real temporary directories.
struct TrashVectorsTests {
    static let expectedSHA256 = "e221e0b5c355cfab68b107e6493ca98e07588a2e7e78b3ef352d5624f8a72d76"

    private static let vectorProbe: LibraryTrash.IdentityProbe = { url in
        let text = try String(contentsOf: url, encoding: .utf8)
        if text.hasPrefix("opus id=") {
            return PublishedProbeResult(identity: .session(String(text.dropFirst("opus id=".count))))
        }
        if text.hasPrefix("opus sha=") {
            return PublishedProbeResult(identity: .sha(String(text.dropFirst("opus sha=".count))))
        }
        throw POSIXError(.EINVAL)
    }

    private func loadVectors() throws -> JSON {
        let url = try #require(
            Bundle.module.url(forResource: "trash-vectors", withExtension: "json", subdirectory: "Golden/library-v2")
        )
        let data = try Data(contentsOf: url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(sha == Self.expectedSHA256, "trash-vectors.json must match pinned upstream SHA-256")
        return try JSONParser.parse(data)
    }

    private func parseInternalRequest(_ req: JSON) throws -> LibraryTrash.InternalRequest {
        let kind = try #require(req["op"]?.string)
        switch kind {
        case "trash":
            return .trash(TrashRequest(
                entryId: try #require(req["entryId"]?.string),
                deletedAtUtc: try #require(req["deletedAtUtc"]?.string),
                title: try #require(req["title"]?.string),
                recordedAtUtc: req["recordedAtUtc"]?.string,
                durationMs: req["durationMs"]?.int,
                published: req["published"]?.string,
                session: req["session"]?.string,
                namePrefix: req["namePrefix"]?.string,
                activeLease: req["activeLease"] == .bool(true)
            ))
        case "restore":
            return .restore(entryId: try #require(req["entryId"]?.string))
        case "purge":
            return .purge(entryId: try #require(req["entryId"]?.string))
        case "emptyTrash":
            return .emptyTrash
        default:
            throw POSIXError(.EINVAL)
        }
    }

    private func materialize(files: JSON?, dirs: JSON?, into root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for dirItem in dirs?.array ?? [] {
            if let rel = dirItem.string {
                let url = URL(fileURLWithPath: root.path + "/" + rel)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
        for (rel, val) in files?.object ?? [] {
            let content = try #require(val.string)
            let url = URL(fileURLWithPath: root.path + "/" + rel)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: url)
        }
    }

    struct DiskView: Equatable {
        struct LibRow: Equatable {
            let kind: String
            let name: String
            let identity: String
        }
        struct TrashRow: Equatable {
            let entryId: String
            let title: String
            let deletedAtUtc: String
            let identity: String
        }
        var files: [String: String]
        var emptyDirs: [String]
        var libraryRows: [LibRow]
        var trashRows: [TrashRow]
    }

    private func inspectDisk(at root: URL) throws -> DiskView {
        var files: [String: String] = [:]
        var allDirs: [String] = []

        func walk(_ dir: URL, prefix: String) throws {
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            for name in names {
                let rel = prefix.isEmpty ? name : "\(prefix)/\(name)"
                if rel == LibraryTrash.libraryLockPath { continue }
                let full = URL(fileURLWithPath: dir.path + "/" + name)
                var info = stat()
                guard lstat(full.path, &info) == 0 else { continue }
                if (info.st_mode & S_IFMT) == S_IFDIR {
                    allDirs.append(rel)
                    try walk(full, prefix: rel)
                } else if (info.st_mode & S_IFMT) == S_IFREG {
                    files[rel] = try String(contentsOf: full, encoding: .utf8)
                }
            }
        }
        try walk(root, prefix: "")

        let emptyDirs = allDirs.filter { d in
            // `.cassini` and `.cassini/sessions` are implicit parent directories on POSIX when files
            // lived under them, whereas trash.py only records explicit leaf dirs (.cassini/journal, .cassini/trash).
            if d == ".cassini" || d == LibraryTrash.sessionsDirectory { return false }
            let prefix = d + "/"
            return !files.keys.contains(where: { $0.hasPrefix(prefix) })
                && !allDirs.contains(where: { $0.hasPrefix(prefix) })
        }.sorted()

        // Reconciled Library rows matching S-12 §1 / trash.py library_rows(fs)
        var libRows: [DiskView.LibRow] = []
        var publishedIds = Set<String>()
        let rootNames = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        for name in rootNames where !name.hasPrefix(".") {
            let full = URL(fileURLWithPath: root.path + "/" + name)
            var info = stat()
            guard lstat(full.path, &info) == 0 else { continue }
            if (info.st_mode & S_IFMT) == S_IFREG, name.hasSuffix(".opus") {
                let ident = try Self.vectorProbe(full).identity.key
                publishedIds.insert(ident)
                libRows.append(.init(kind: "published", name: name, identity: ident))
            } else if (info.st_mode & S_IFMT) == S_IFDIR, LibraryScanner.identity(name) != nil {
                libRows.append(.init(kind: "v1Folder", name: name, identity: name))
            }
        }
        let sessionsURL = URL(fileURLWithPath: root.path + "/" + LibraryTrash.sessionsDirectory)
        if let sessNames = try? FileManager.default.contentsOfDirectory(atPath: sessionsURL.path).sorted() {
            for name in sessNames where !publishedIds.contains(name) && LibraryScanner.identity(name) != nil {
                libRows.append(.init(kind: "unpublished", name: name, identity: name))
            }
        }

        let entries = try LibraryTrash.listEntriesUnlocked(in: root)
        let trashRows = entries.map {
            DiskView.TrashRow(
                entryId: $0.entryId,
                title: $0.display.title,
                deletedAtUtc: $0.deletedAtUtc,
                identity: $0.identity.key
            )
        }
        return DiskView(files: files, emptyDirs: emptyDirs, libraryRows: libRows, trashRows: trashRows)
    }

    private func parseExpectedView(_ json: JSON) throws -> DiskView {
        let state = try #require(json["state"])
        var files: [String: String] = [:]
        for (k, v) in state["files"]?.object ?? [] {
            files[k] = try #require(v.string as String?)
        }
        let emptyDirs = state["emptyDirs"]?.array?.compactMap(\.string) ?? []
        let libRows = try (json["libraryRows"]?.array ?? []).map { row in
            DiskView.LibRow(
                kind: try #require(row["kind"]?.string),
                name: try #require(row["name"]?.string),
                identity: try #require(row["identity"]?.string)
            )
        }
        let trashRows = try (json["trashRows"]?.array ?? []).map { row in
            DiskView.TrashRow(
                entryId: try #require(row["entryId"]?.string),
                title: try #require(row["title"]?.string),
                deletedAtUtc: try #require(row["deletedAtUtc"]?.string),
                identity: try #require(row["identity"]?.string)
            )
        }
        return DiskView(files: files, emptyDirs: emptyDirs, libraryRows: libRows, trashRows: trashRows)
    }

    private func parseExpectedSteps(_ json: JSON) throws -> [TrashStep] {
        try (json.array ?? []).map { item in
            TrashStep(
                action: try #require(item["do"]?.string),
                path: item["path"]?.string,
                content: item["content"]?.string,
                from: item["from"]?.string,
                to: item["to"]?.string,
                nameFrom: item["nameFrom"]?.string
            )
        }
    }

    private func setupBeforeState(input: JSON, untitled: String, in root: URL) throws {
        try materialize(files: input["files"], dirs: input["dirs"], into: root)
        for (index, reqJSON) in (input["before"]?.array ?? []).enumerated() {
            let req = try parseInternalRequest(reqJSON)
            let op = String(format: "op-0%d", index + 1)
            let steps = try LibraryTrash.plan(
                in: root,
                op: op,
                request: req,
                untitled: untitled,
                probe: Self.vectorProbe
            )
            try LibraryTrash.executeSteps(steps, in: root, untitled: untitled, probe: Self.vectorProbe)
        }
        if let extra = input["putAfterBefore"] {
            try materialize(files: extra, dirs: nil, into: root)
        }
    }

    private func checkInvariants(caseId: String, opKind: String, before: DiskView, states: [DiskView]) {
        let beforeRows = before.libraryRows.map(\.identity) + before.trashRows.map(\.identity)
        let beforeIds = Set(beforeRows)
        let beforeDupes = beforeRows.count - beforeIds.count

        for (index, st) in states.enumerated() {
            let whereLabel = "\(caseId) state \(index)"
            let rows = st.libraryRows.map(\.identity) + st.trashRows.map(\.identity)
            #expect(rows.count - Set(rows).count <= beforeDupes, "\(whereLabel): duplicate identity across Library and Trash")
            #expect(Set(rows).isSubset(of: beforeIds), "\(whereLabel): identity appeared from nowhere")
            for path in st.files.keys {
                #expect(!path.hasPrefix(LibraryTrash.journalDirectory + "/"), "\(whereLabel): journal left after recovery: \(path)")
                #expect(!path.contains("/.purge-"), "\(whereLabel): purge leftover: \(path)")
                if path.hasPrefix(LibraryTrash.trashDirectory + "/") {
                    let entryId = path.dropFirst(LibraryTrash.trashDirectory.count + 1).split(separator: "/").first.map(String.init) ?? ""
                    let entryFile = "\(LibraryTrash.trashDirectory)/\(entryId)/\(LibraryTrash.entryFileName)"
                    #expect(st.files[entryFile] != nil, "\(whereLabel): trash content without entry.json: \(path)")
                }
            }
        }
        if let finalState = states.first, (opKind == "trash" || opKind == "restore") {
            let finalIds = Set(finalState.libraryRows.map(\.identity) + finalState.trashRows.map(\.identity))
            #expect(finalIds == beforeIds, "\(caseId): move lost or gained a meeting")
        }
    }

    @Test func allTrashCasesAndCrashMatrices() throws {
        let doc = try loadVectors()
        let untitled = try #require(doc["untitled"]?.string)
        let cases = try #require(doc["cases"]?.array)
        #expect(cases.count == 30)

        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashVectors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        var totalCrashPoints = 0

        for vector in cases {
            let id = try #require(vector["id"]?.string)
            let input = try #require(vector["input"])
            let expected = try #require(vector["expected"])
            let reqJSON = try #require(input["request"])
            let opKind = try #require(reqJSON["op"]?.string)
            let req = try parseInternalRequest(reqJSON)

            let expectedBefore = try parseExpectedView(#require(expected["before"]))
            let expectedAfter = try parseExpectedView(#require(expected["after"]))

            let mainRoot = tempBase.appendingPathComponent("\(id)-main")
            try setupBeforeState(input: input, untitled: untitled, in: mainRoot)
            let actualBefore = try inspectDisk(at: mainRoot)
            #expect(actualBefore == expectedBefore, "\(id): before state mismatch")

            let resultKind = try #require(expected["result"]?.string)
            if resultKind == "refused" {
                let expectedReason = try #require(expected["reason"]?.string)
                do {
                    _ = try LibraryTrash.plan(
                        in: mainRoot,
                        op: "op-1",
                        request: req,
                        untitled: untitled,
                        probe: Self.vectorProbe
                    )
                    Issue.record("\(id): expected refusal '\(expectedReason)'")
                } catch TrashError.refused(let actualReason) {
                    #expect(actualReason == expectedReason, "\(id): refusal reason")
                }
                let actualAfter = try inspectDisk(at: mainRoot)
                #expect(actualAfter == expectedAfter, "\(id): refused request must not change disk")
                continue
            }

            #expect(resultKind == "ok")
            let expectedSteps = try parseExpectedSteps(#require(expected["steps"]))
            let plannedSteps = try LibraryTrash.plan(
                in: mainRoot,
                op: "op-1",
                request: req,
                untitled: untitled,
                probe: Self.vectorProbe
            )
            #expect(plannedSteps == expectedSteps, "\(id): planned steps mismatch")

            try LibraryTrash.executeSteps(plannedSteps, in: mainRoot, untitled: untitled, probe: Self.vectorProbe)
            let actualAfter = try inspectDisk(at: mainRoot)
            #expect(actualAfter == expectedAfter, "\(id): after state mismatch")

            var statesToVerify: [DiskView] = [actualAfter]
            let matrix = expected["crashMatrix"]?.array ?? []
            for m in matrix {
                totalCrashPoints += 1
                let k = try #require(m["crashAfterStep"]?.int)
                let expectedRecovery = (m["recovery"]?.array ?? []).compactMap(\.string)
                let expectedRecoveredView = try parseExpectedView(#require(m["afterRecovery"]))

                let crashRoot = tempBase.appendingPathComponent("\(id)-crash-\(k)")
                try setupBeforeState(input: input, untitled: untitled, in: crashRoot)
                try LibraryTrash.executeSteps(
                    plannedSteps,
                    in: crashRoot,
                    untitled: untitled,
                    probe: Self.vectorProbe,
                    stopAfterStep: k
                )
                let report = try LibraryTrash.recover(
                    in: crashRoot,
                    untitled: untitled,
                    now: Date(timeIntervalSince1970: 1_794_648_600),
                    probe: Self.vectorProbe
                )
                let recoveredView = try inspectDisk(at: crashRoot)
                #expect(report == expectedRecovery, "\(id) crash \(k): recovery report mismatch")
                #expect(recoveredView == expectedRecoveredView, "\(id) crash \(k): afterRecovery mismatch")
                statesToVerify.append(recoveredView)
            }

            checkInvariants(caseId: id, opKind: opKind, before: actualBefore, states: statesToVerify)
        }

        #expect(totalCrashPoints == 125)
    }

    @Test func allDaysLeftVectors() throws {
        let doc = try loadVectors()
        let vectors = try #require(doc["daysLeft"]?.array)
        #expect(vectors.count == 8)
        for v in vectors {
            let id = try #require(v["id"]?.string)
            let deleted = try #require(v["deletedAtUtc"]?.string)
            let now = try #require(v["nowUtc"]?.string)
            let expectedDays = try #require(v["daysLeft"]?.int)
            let expectedExpired = try #require(v["expired"]?.bool as Bool?)
            let expectedDisplay = try #require(v["display"]?.string)

            let got = try LibraryTrash.daysLeft(deletedAtUtc: deleted, nowUtc: now)
            #expect(got.daysLeft == expectedDays, "daysLeft \(id)")
            #expect(got.expired == expectedExpired, "expired \(id)")

            let display = got.expired
                ? "expired"
                : (got.daysLeft < 1 ? "trash.row.lessThanDay" : "trash.row.daysLeft")
            #expect(display == expectedDisplay, "display \(id)")
        }
    }
}
