// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CassiniRecording

private struct CaptureDiskSample: Sendable {
    let now: TimeInterval
    var volumes: [UInt64:[UUID]] = [:]
    var representatives: [UInt64:URL] = [:]
    var bytes: [UUID:UInt64] = [:]
}
/// Sampling and filesystem queries leave the UI actor. Budgets use the total
/// current capture write rate on each volume, including independent meetings.
@MainActor final class CaptureDiskWatch {
    private var timer: Timer?
    private var sampling: Task<Void,Never>?
    private var rates = CaptureWriteRates()
    private var generation = 0
    func start(folders: @escaping @MainActor () -> [UUID:(URL,Double)], update: @escaping @MainActor ([UUID],DiskBudget) -> Void) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in MainActor.assumeIsolated {
            guard let self, self.sampling == nil else { return }
            let folders = folders(), generation = self.generation
            guard !folders.isEmpty else { return }
            self.sampling = Task { [weak self] in
                let sample = await Task.detached { Self.sample(folders) }.value
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                let rates = self.rates.observe(bytes:sample.bytes,at:sample.now,initialRates:folders.mapValues(\.1))
                let budgets = await Task.detached {
                    sample.volumes.compactMap { volume,ids -> ([UUID],DiskBudget)? in
                        guard let root = sample.representatives[volume],
                              let budget = RecordingDiskWatch.inspect(root,rate:ids.reduce(0) { $0 + (rates[$1] ?? 0) }) else { return nil }
                        return (ids,budget)
                    }
                }.value
                guard !Task.isCancelled, self.generation == generation else { return }
                self.sampling = nil
                for (ids,budget) in budgets { update(ids,budget) }
            }
        } }
    }
    func stop() { generation += 1; timer?.invalidate(); timer = nil; sampling?.cancel(); sampling = nil }
    nonisolated private static func sample(_ folders: [UUID:(URL,Double)]) -> CaptureDiskSample {
        var result = CaptureDiskSample(now:ProcessInfo.processInfo.systemUptime)
        for (id,pair) in folders {
            let folder = pair.0
            var info = stat()
            guard lstat(folder.path,&info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            let volume = UInt64(UInt32(bitPattern:info.st_dev))
            result.volumes[volume,default:[]].append(id); result.representatives[volume] = folder
            let files = (try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey])) ?? []
            result.bytes[id] = files.filter { $0.pathExtension == "wav" }.reduce(UInt64(0)) { total,file in
                guard let values = try? file.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey]), values.isRegularFile == true else { return total }
                return total + UInt64(max(0,values.fileSize ?? 0))
            }
        }
        return result
    }
}
