// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import Observation
import CassiniLibrary

@MainActor @Observable final class LibraryLocationModel {
    static let shared = LibraryLocationModel()
    private(set) var location: LibraryLocation
    private(set) var problem: String?
    @ObservationIgnored private var access: LibraryAccess?
    var roots: [URL] { access?.roots ?? location.roots }
    var available: Bool {
        guard problem == nil else { return false }
        if FileManager.default.fileExists(atPath:LibraryLaunchContext.locationFile.path), roots[0].path != LibraryLocation.standardRoot.path {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath:roots[0].path,isDirectory:&directory) && directory.boolValue
        }
        return true
    }
    var displayPath: String { Self.display(roots[0]) }
    static func display(_ root: URL) -> String {
        let path = root.path, home = LibraryLocation.userHome.path + "/"
        return (path.hasPrefix(home) ? String(path.dropFirst(home.count)) : path).split(separator:"/").joined(separator:" › ")
    }
    private init() {
        let context = LibraryLaunchContext.current
        location = .init(primary:context.root,previous:context.previousRoots)
        reload()
    }
    func reload() {
        do {
            let context = LibraryLaunchContext.current
            let value = try LibraryLocation.read(file:LibraryLaunchContext.locationFile,defaultRoot:context.root)
            let lease = try LibraryAccess(value,tolerateMissingPrevious:true)
            if let primary = lease.roots.first, primary.path != LibraryLocation.standardRoot.path,
               FileManager.default.fileExists(atPath:LibraryLaunchContext.locationFile.path) {
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath:primary.path,isDirectory:&directory), directory.boolValue else { throw POSIXError(.ENOENT) }
            }
            var bookmarks: [String:Data] = [:]
            for (original,resolved) in zip(value.roots,lease.roots) where bookmarks[resolved.path] == nil {
                bookmarks[resolved.path] = value.bookmarks[original.path]
            }
            let mapping = Dictionary(uniqueKeysWithValues:zip(value.roots,lease.roots).map { ($0.0.path,$0.1.path) })
            let moves = value.pendingMoves.map { move -> LibraryPendingMove in var result = move; result.sourcePath = mapping[move.sourcePath] ?? move.sourcePath; return result }
            let updated = LibraryLocation(primary:lease.roots[0],previous:Array(lease.roots.dropFirst()),bookmarks:bookmarks,pendingMoves:moves)
            if updated != value, FileManager.default.fileExists(atPath:LibraryLaunchContext.locationFile.path) {
                try updated.write(file:LibraryLaunchContext.locationFile)
            }
            location = updated; access = lease; problem = nil
        } catch { problem = error.localizedDescription }
    }
    func choose(_ url: URL) throws {
        try LibraryRouting.withLock(file:LibraryLaunchContext.locationFile,exclusive:true,wait:false) { try chooseLocked(url) }
    }
    private func chooseLocked(_ url: URL) throws {
        let canonical = LibraryLocation.canonical(url)
        guard !roots.contains(where:{
            let path = LibraryLocation.canonical($0).path
            return path == canonical.path || canonical.path.hasPrefix(path + "/") || path.hasPrefix(canonical.path + "/")
        }) else { throw POSIXError(.EINVAL) }
        let configured = FileManager.default.fileExists(atPath:LibraryLaunchContext.locationFile.path)
        let previous = roots.filter { root in
            if configured || FileManager.default.fileExists(atPath:root.path) { return true }
            var parent = stat()
            return lstat(root.deletingLastPathComponent().path,&parent) != 0 || parent.st_mode & S_IFMT != S_IFDIR
        }
        var bookmarks = location.bookmarks
        bookmarks[canonical.path] = try canonical.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
        var moves: [LibraryPendingMove] = []
        for root in previous {
            let names = Set(location.pendingMoves.filter { $0.sourcePath == root.path }.map(\.folderName))
                .union((try? LibraryMove.remaining(in:root)) ?? [])
                .union(LibraryStore.shared.meetings.filter { LibraryLocation.canonical($0.folder.deletingLastPathComponent()).path == root.path }.map { $0.folder.lastPathComponent })
            moves += names.sorted().map { LibraryPendingMove(source:root,folderName:$0) }
        }
        let candidate = LibraryLocation(primary:canonical,previous:previous,bookmarks:bookmarks,pendingMoves:moves)
        try candidate.write(file:LibraryLaunchContext.locationFile)
        reload()
        if let problem { throw NSError(domain:"CassiniLibraryLocation",code:1,userInfo:[NSLocalizedDescriptionKey:problem]) }
    }
    func replaceMoves(_ moves: [LibraryPendingMove]) throws {
        let sources = Set(moves.map(\.sourcePath))
        let paths = location.roots.dropFirst().filter { sources.contains($0.path) }
        let kept = Set([location.primaryPath] + paths.map(\.path))
        let value = LibraryLocation(primary:location.primary,previous:Array(paths),bookmarks:location.bookmarks.filter { kept.contains($0.key) },pendingMoves:moves)
        try value.write(file:LibraryLaunchContext.locationFile); reload()
    }
    func context() -> LibraryLaunchContext {
        var context = LibraryLaunchContext.current
        context.root = roots[0]; context.previousRoots = Array(roots.dropFirst()); context.locationProblem = problem
        return context
    }
}
