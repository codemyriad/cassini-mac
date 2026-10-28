// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniRecording

@MainActor final class RecordingDiskWatch {
    private var timer: Timer?
    private var previous: (Date, UInt64)?
    private var sampling: Task<Void,Never>?
    private var generation = 0
    private static var warningItem: NSStatusItem?
    nonisolated static func inspect(_ url: URL, rate: Double) -> DiskBudget? {
        #if DEBUG
        if RecordingFixture.enabled,
           let free = LibraryLaunchContext.argument("-CassiniDiskFree").flatMap(UInt64.init),
           let total = LibraryLaunchContext.argument("-CassiniDiskTotal").flatMap(UInt64.init) {
            return DiskBudget(total: total, free: free, bytesPerSecond: rate)
        }
        #endif
        var path = url
        while !FileManager.default.fileExists(atPath: path.path), path.path != "/" { path.deleteLastPathComponent() }
        guard let info = try? FileManager.default.attributesOfFileSystem(forPath: path.path),
              let total = info[.systemSize] as? NSNumber, let free = info[.systemFreeSize] as? NSNumber else { return nil }
        return DiskBudget(total: total.uint64Value, free: free.uint64Value, bytesPerSecond: rate)
    }
    func start(directory: URL, update: @escaping @MainActor @Sendable (DiskBudget) -> Void) {
        stop()
        previous = (Date(), 0)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sampling == nil else { return }
                let revision = self.generation, before = self.previous ?? (Date(),0)
                self.sampling = Task { [weak self] in
                    let result = await Task.detached {
                        let files = (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey])) ?? []
                        let bytes = files.reduce(UInt64(0)) { sum,file in sum + UInt64(max(0,(try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)) }
                        let now = Date()
                        let rate = bytes >= before.1 ? Double(bytes - before.1) / max(0.1,now.timeIntervalSince(before.0)) : 0
                        return (now,bytes,Self.inspect(directory,rate:rate))
                    }.value
                    guard let self, !Task.isCancelled, revision == self.generation else { return }
                    self.sampling = nil; self.previous = (result.0,result.1)
                    if let budget = result.2 { update(budget) }
                }
            }
        }
    }
    func stop() { generation += 1; timer?.invalidate(); timer = nil; sampling?.cancel(); sampling = nil }
    static func updateWarning(_ text: String?) {
        guard let text else { clear(); return }
        let item = warningItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = text; item.button?.toolTip = text
        warningItem = item
    }
    static func clear() { if let item = warningItem { NSStatusBar.system.removeStatusItem(item) }; warningItem = nil }
    #if DEBUG
    static var warningTitle: String? { warningItem?.button?.title }
    #endif
}
