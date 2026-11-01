// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

public struct ModelDiskSpace: Sendable {
    public let free: UInt64
    public let total: UInt64
    public init(free: UInt64, total: UInt64) { self.free = free; self.total = total }
    public var reserve: UInt64 { max(1 << 30,total / 50) }
    public func check(required: UInt64) throws {
        let available = free > reserve ? free - reserve : 0
        guard required <= available else { throw ModelDownloadError.diskSpace(required:required,available:available) }
    }
    static func measured(_ root: URL) throws -> Self {
        let values = try FileManager.default.attributesOfFileSystem(forPath:root.path)
        guard let free = values[.systemFreeSize] as? NSNumber, let total = values[.systemSize] as? NSNumber else { throw ModelDownloadError.installation }
        return .init(free:free.uint64Value,total:total.uint64Value)
    }
}
public struct ModelDownloadProgress: Sendable, Equatable {
    public let receivedBytes: UInt64
    public let totalBytes: UInt64
    /// True only after both hashes and atomic installation, including reuse.
    public let isInstalled: Bool
    public var fraction: Double { totalBytes == 0 ? 0 : min(1,Double(receivedBytes)/Double(totalBytes)) }
}
/// Explicit calls only: constructing this object performs no network requests.
/// Future UI rows must supply their published (id, source_sha256), never latest.
public actor ModelDownloader {
    private let dataRoot: URL
    private let origin: ModelOrigin
    private let budget: @Sendable (URL) throws -> ModelDiskSpace
    /// D54: sent on every request (manifest, NOTICE, artifacts and any redirect hop).
    private let userAgent: String
    private struct Operation { let id: UUID; let task: Task<URL,Error> }
    private var operations: [ModelPin:Operation] = [:]
    private var removing = Set<ModelPin>()
    /// `userAgent`: `ModelUserAgent.app()`, built once by the app layer.
    public init(appData: URL, userAgent: String) {
        dataRoot = appData.resolvingSymlinksInPath(); self.userAgent = userAgent
        origin = try! ModelOrigin(URL(string:"https://dist.gocassini.com")!)
        budget = ModelDiskSpace.measured
    }
    // Loopback HTTP is available only to module tests, never the app consumer.
    init(appData: URL, fixtureOrigin: URL, userAgent: String, budget: @escaping @Sendable (URL) throws -> ModelDiskSpace = ModelDiskSpace.measured) throws {
        dataRoot = appData.resolvingSymlinksInPath(); self.userAgent = userAgent; origin = try ModelOrigin(fixtureOrigin,fixture:true); self.budget = budget
    }
    public func plan(_ pin: ModelPin) async throws -> ModelPlan {
        guard pin.valid else { throw ModelDownloadError.manifest }
        try ModelFiles.directory(dataRoot)
        let manifest = try await Self.metadata(origin.endpoint("manifest.json"),origin:origin,userAgent:userAgent,temporary:dataRoot,limit:4 << 20)
        return try ModelManifest.plan(manifest,pin:pin,origin:origin)
    }
    public func spaceRequired(for plan: ModelPlan) throws -> UInt64 {
        try budget(dataRoot).check(required:plan.spaceRequired)
        return plan.spaceRequired
    }
    /// The caller starting a transfer owns its progress callback. Coalesced
    /// awaiters share its result; they do not start another transfer.
    public func install(_ pin: ModelPin, progress: @escaping @Sendable (ModelDownloadProgress) -> Void = { _ in }) async throws -> URL {
        guard pin.valid else { throw ModelDownloadError.manifest }
        guard !removing.contains(pin) else { throw ModelDownloadError.busy }
        if let operation = operations[pin] { return try await operation.task.value }
        guard operations.isEmpty else { throw ModelDownloadError.busy }
        let id = UUID(), root = dataRoot, origin = origin, budget = budget, userAgent = userAgent
        let task = Task.detached(priority:.utility) { try await Self.perform(pin,root:root,origin:origin,userAgent:userAgent,budget:budget,progress:progress) }
        operations[pin] = .init(id:id,task:task)
        defer { if operations[pin]?.id == id { operations[pin] = nil } }
        return try await withTaskCancellationHandler(operation:{ try await task.value },onCancel:{ task.cancel() })
    }
    public func cancel(_ pin: ModelPin) { operations[pin]?.task.cancel() }
    public func remove(_ pin: ModelPin) async throws {
        _ = try await remove(pin,unlessValid:nil)
    }
    /// Recheck after acquiring the revision lock: an old inventory result must
    /// not delete an installation another helper finished in the meantime.
    public func removeInvalid(_ plan: ModelPlan) async throws -> Bool {
        guard operations[plan.pin] == nil else { throw ModelDownloadError.busy }
        return try await remove(plan.pin,unlessValid:plan)
    }
    private func remove(_ pin: ModelPin, unlessValid plan: ModelPlan?) async throws -> Bool {
        guard pin.valid else { throw ModelDownloadError.manifest }
        guard removing.insert(pin).inserted else { throw ModelDownloadError.busy }
        defer { removing.remove(pin) }
        if let operation = operations[pin] { operation.task.cancel(); _ = try? await operation.task.value }
        try ModelFiles.directory(dataRoot)
        let modelRoot = dataRoot.appendingPathComponent("models/" + pin.id,isDirectory:true)
        try ModelFiles.directory(modelRoot)
        let lock = try await Self.removalLock(modelRoot.appendingPathComponent("." + pin.sourceSHA256 + ".lock")); defer { close(lock) }
        let installed = modelRoot.appendingPathComponent(pin.sourceSHA256,isDirectory:true)
        if FileManager.default.fileExists(atPath:installed.path) {
            try ModelFiles.directory(installed)
            if let plan {
                do { try Self.validateInstalled(installed,plan:plan,verifyHashes:true); return false }
                catch is CancellationError { throw CancellationError() }
                catch { /* Retire only the still-invalid owned revision. */ }
            }
            try Task.checkCancellation()
            try Self.retire(installed,in:modelRoot)
        }
        let partials = Self.cache(root:dataRoot,pin:pin)
        if FileManager.default.fileExists(atPath:partials.path) { try ModelFiles.directory(partials); try FileManager.default.removeItem(at:partials) }
        return true
    }
    private static func cache(root: URL, pin: ModelPin) -> URL { root.appendingPathComponent("model-downloads/" + pin.id + "/" + pin.sourceSHA256,isDirectory:true) }
    private static func lock(_ file: URL) throws -> Int32 {
        let fd = open(file.path,O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,0o600)
        guard fd >= 0 else { throw ModelDownloadError.unsafePath }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { close(fd); throw ModelDownloadError.unsafePath }
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { close(fd); throw ModelDownloadError.busy }
        return fd
    }
    private static func removalLock(_ file: URL) async throws -> Int32 {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while true {
            try Task.checkCancellation()
            do { return try lock(file) }
            catch ModelDownloadError.busy {
                guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ModelDownloadError.busy }
                try await Task.sleep(for:.milliseconds(50))
            }
        }
    }
    private static func retire(_ installed: URL, in modelRoot: URL) throws {
        try ModelFiles.directory(installed)
        let retired = modelRoot.appendingPathComponent(".remove-" + UUID().uuidString,isDirectory:true)
        guard renamex_np(installed.path,retired.path,UInt32(RENAME_EXCL)) == 0 else { throw ModelDownloadError.installation }
        try FileManager.default.removeItem(at:retired)
    }
    static func validateInstalled(_ destination: URL, plan: ModelPlan, verifyHashes: Bool) throws {
        let receipt = destination.appendingPathComponent("receipt.json")
        guard let size = try ModelFiles.size(receipt),size <= 1 << 20,
              try JSONDecoder().decode(Receipt.self,from:Data(contentsOf:receipt)).matches(plan) else { throw ModelDownloadError.installation }
        for asset in plan.files {
            var parent = destination.appendingPathComponent(asset.path).deletingLastPathComponent()
            while parent.path != destination.path {
                guard ModelFiles.existingDirectory(parent) else { throw ModelDownloadError.unsafePath }
                parent.deleteLastPathComponent()
            }
            let file = destination.appendingPathComponent(asset.path)
            // Accepted inference jobs retain immutable model assets through hard
            // links. Receipts, notices and transfer/staging files stay single-link.
            guard try ModelFiles.size(file,allowingInferenceLinks:true) == asset.rawBytes else { throw ModelDownloadError.installation }
            if verifyHashes,try ModelFiles.digest(file,allowingInferenceLinks:true) != asset.rawSHA256 { throw ModelDownloadError.hash }
        }
        let notice = destination.appendingPathComponent("NOTICE.txt")
        guard let size = try ModelFiles.size(notice),size > 0,size <= 2 << 20,
              String(data:try Data(contentsOf:notice),encoding:.utf8) != nil else { throw ModelDownloadError.installation }
    }
    private static func perform(_ pin: ModelPin, root: URL, origin: ModelOrigin, userAgent: String,
                                budget: @Sendable (URL) throws -> ModelDiskSpace, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws -> URL {
        try ModelFiles.directory(root)
        let modelsRoot = root.appendingPathComponent("models",isDirectory:true)
        try ModelFiles.directory(modelsRoot)
        let globalLock = try lock(modelsRoot.appendingPathComponent(".download.lock")); defer { close(globalLock) }
        let modelRoot = modelsRoot.appendingPathComponent(pin.id,isDirectory:true)
        try ModelFiles.directory(modelRoot)
        let lock = try lock(modelRoot.appendingPathComponent("." + pin.sourceSHA256 + ".lock")); defer { close(lock) }
        let destination = modelRoot.appendingPathComponent(pin.sourceSHA256,isDirectory:true)
        let manifest = try await metadata(origin.endpoint("manifest.json"),origin:origin,userAgent:userAgent,temporary:root,limit:4 << 20)
        let plan = try ModelManifest.plan(manifest,pin:pin,origin:origin)
        progress(.init(receivedBytes:0,totalBytes:plan.compressedBytes,isInstalled:false))
        if FileManager.default.fileExists(atPath:destination.path) {
            try ModelFiles.directory(destination)
            do {
                try validateInstalled(destination,plan:plan,verifyHashes:true)
                progress(.init(receivedBytes:plan.compressedBytes,totalBytes:plan.compressedBytes,isInstalled:true))
                return destination
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                try budget(root).check(required:plan.spaceRequired)
                // Only an owned non-symlink installation is retired. The
                // revision lock protects this explicit Download repair.
                try retire(destination,in:modelRoot)
            }
        }
        try budget(root).check(required:plan.spaceRequired)
        let partials = cache(root:root,pin:pin); try ModelFiles.directory(partials)
        let staging = modelRoot.appendingPathComponent(".install-" + UUID().uuidString,isDirectory:true)
        try ModelFiles.directory(staging)
        defer { try? FileManager.default.removeItem(at:staging) }
        var completedBytes: UInt64 = 0
        for asset in plan.files {
            try Task.checkCancellation()
            let compressed = partials.appendingPathComponent(asset.compressedSHA256 + ".part")
            let before = completedBytes, total = plan.compressedBytes
            try await download(asset,to:compressed,origin:origin,userAgent:userAgent) { bytes in
                progress(.init(receivedBytes:before + bytes,totalBytes:total,isInstalled:false))
            }
            let decoded = staging.appendingPathComponent(asset.path)
            try ModelFiles.directory(decoded.deletingLastPathComponent())
            try ModelFiles.decode(asset,compressed:compressed,output:decoded)
            completedBytes += asset.compressedBytes
        }
        let notice = try await metadata(origin.endpoint("NOTICE.txt"),origin:origin,userAgent:userAgent,temporary:root,limit:2 << 20)
        guard !notice.isEmpty, String(data:notice,encoding:.utf8) != nil else { throw ModelDownloadError.response }
        try save(notice,to:staging.appendingPathComponent("NOTICE.txt"))
        try save(try JSONEncoder().encode(Receipt(plan:plan)),to:staging.appendingPathComponent("receipt.json"))
        try Task.checkCancellation()
        var directories: Set<URL> = [staging]
        for asset in plan.files {
            var parent = staging.appendingPathComponent(asset.path).deletingLastPathComponent()
            while parent.path != staging.path { directories.insert(parent); parent.deleteLastPathComponent() }
        }
        for directory in directories.sorted(by:{ $0.path.count > $1.path.count }) {
            let fd = open(directory.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ModelDownloadError.installation }
            let synced = fsync(fd); close(fd)
            guard synced == 0 else { throw ModelDownloadError.installation }
        }
        let folder = open(staging.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw ModelDownloadError.installation }; defer { close(folder) }
        guard fsync(folder) == 0, renamex_np(staging.path,destination.path,UInt32(RENAME_EXCL)) == 0 else { throw ModelDownloadError.installation }
        let parent = open(modelRoot.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if parent >= 0 { _ = fsync(parent); close(parent) }
        try? FileManager.default.removeItem(at:partials)
        progress(.init(receivedBytes:plan.compressedBytes,totalBytes:plan.compressedBytes,isInstalled:true))
        return destination
    }
    private struct Receipt: Codable {
        let pin: ModelPin
        let files: [ModelAsset]
        init(plan: ModelPlan) { pin = plan.pin; files = plan.files }
        func matches(_ plan: ModelPlan) -> Bool { pin == plan.pin && files == plan.files }
    }
    private static func save(_ bytes: Data, to url: URL) throws {
        let fd = open(url.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw ModelDownloadError.unsafePath }
        let file = FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer { try? file.close() }
        try file.write(contentsOf:bytes); try file.synchronize()
    }
    private static func metadata(_ url: URL, origin: ModelOrigin, userAgent: String, temporary: URL, limit: UInt64) async throws -> Data {
        guard origin.permits(url) else { throw ModelDownloadError.origin }
        let file = temporary.appendingPathComponent(".metadata-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:file) }
        var request = URLRequest(url:url); request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
        _ = try await ModelHTTP.transfer(request,userAgent:userAgent,to:file,limit:limit) { response in
            guard response.statusCode == 200 else { throw ModelDownloadError.response }; return .replace
        }
        try Task.checkCancellation()
        return try Data(contentsOf:file)
    }
    private static func download(_ asset: ModelAsset, to file: URL, origin: ModelOrigin, userAgent: String, progress: @escaping @Sendable (UInt64) -> Void) async throws {
        guard origin.permits(asset.url) else { throw ModelDownloadError.origin }
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let existing = try ModelFiles.size(file) ?? 0
            if existing == asset.compressedBytes {
                if try ModelFiles.digest(file) == asset.compressedSHA256 { progress(existing); return }
                try FileManager.default.removeItem(at:file); throw ModelDownloadError.hash
            }
            if existing > asset.compressedBytes { try FileManager.default.removeItem(at:file); throw ModelDownloadError.tooLarge }
            var request = URLRequest(url:asset.url)
            request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
            let etag = "\"" + asset.compressedSHA256 + "\""
            if existing > 0 { request.setValue("bytes=\(existing)-",forHTTPHeaderField:"Range"); request.setValue(etag,forHTTPHeaderField:"If-Range") }
            do {
                let response = try await ModelHTTP.transfer(request,userAgent:userAgent,to:file,limit:asset.compressedBytes,progress:progress) { response in
                    if response.statusCode == 416 && existing > 0 { return .ignore }
                    guard response.statusCode == 200 || response.statusCode == 206 else { throw ModelDownloadError.response }
                    guard response.value(forHTTPHeaderField:"ETag") == etag else { throw ModelDownloadError.etag }
                    let length = response.value(forHTTPHeaderField:"Content-Length").flatMap(UInt64.init)
                    if response.statusCode == 200 {
                        guard length == nil || length == asset.compressedBytes else { throw ModelDownloadError.response }; return .replace
                    }
                    if response.statusCode == 206 && existing > 0 {
                        guard length == nil || length == asset.compressedBytes - existing,
                              response.value(forHTTPHeaderField:"Content-Range") == "bytes \(existing)-\(asset.compressedBytes - 1)/\(asset.compressedBytes)" else { throw ModelDownloadError.range }
                        return .append
                    }
                    throw ModelDownloadError.response
                }
                if response.statusCode == 416 {
                    if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) }
                    if attempt == 0 { continue }; throw ModelDownloadError.range
                }
                try Task.checkCancellation()
                guard try ModelFiles.size(file) == asset.compressedBytes else { throw ModelDownloadError.truncated }
                guard try ModelFiles.digest(file) == asset.compressedSHA256 else { throw ModelDownloadError.hash }
                return
            } catch let error as ModelDownloadError {
                // Invalid identity/headers/hash are not resumable. A transport
                // truncation/cancel keeps the bounded immutable-object prefix.
                if error != .truncated && error != .response { try? FileManager.default.removeItem(at:file) }
                throw error
            }
        }
        throw ModelDownloadError.range
    }
}
