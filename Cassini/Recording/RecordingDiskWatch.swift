// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniRecording

@MainActor final class RecordingDiskWatch {
    private var timer: Timer?
    private var previous: (Date, UInt64)?
    private static var warningItem: NSStatusItem?
    static func inspect(_ url: URL, rate: Double) -> DiskBudget? {
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
    func start(directory: URL, update: @escaping (DiskBudget) -> Void) {
        previous = (Date(), 0)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                let bytes = files.reduce(UInt64(0)) { sum, file in sum + UInt64(max(0, (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)) }
                let now = Date(), before = self.previous ?? (now,0)
                let rate = bytes >= before.1 ? Double(bytes - before.1) / max(0.1, now.timeIntervalSince(before.0)) : 0
                self.previous = (now,bytes)
                if let budget = Self.inspect(directory, rate: rate) { update(budget) }
            }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }
    static func showOnce(_ text: String) {
        guard warningItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = text; item.button?.toolTip = text
        warningItem = item
    }
    static func clear() { if let item = warningItem { NSStatusBar.system.removeStatusItem(item) }; warningItem = nil }
}
