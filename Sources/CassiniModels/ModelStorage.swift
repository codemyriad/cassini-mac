// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum ModelStorage {
    /// Offline inventory. The app may skip the large hashes for its initial
    /// Settings row; accepted inference jobs still verify their pinned files.
    public static func isInstalled(_ plan: ModelPlan, in appData: URL, verifyHashes: Bool = true) -> Bool {
        let models = appData.appendingPathComponent("models"), revisions = models.appendingPathComponent(plan.pin.id)
        let folder = revisions.appendingPathComponent(plan.pin.sourceSHA256)
        guard ModelFiles.existingDirectory(models),ModelFiles.existingDirectory(revisions),ModelFiles.existingDirectory(folder) else { return false }
        do { try ModelDownloader.validateInstalled(folder,plan:plan,verifyHashes:verifyHashes); return true }
        catch { return false }
    }
    /// Foundation resolves Application Support inside the app's container for
    /// sandbox builds. Models are app data, never part of the meeting Library.
    public static var appData: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Cassini",isDirectory:true)
    }
    /// Read-only inventory for About. No directory creation or network activity.
    public static func notices(in appData: URL) -> [URL] {
        let models = appData.appendingPathComponent("models",isDirectory:true)
        guard FileManager.default.fileExists(atPath:models.path), ModelFiles.existingDirectory(models),
              let ids = try? FileManager.default.contentsOfDirectory(atPath:models.path), ids.count <= 1024 else { return [] }
        var output: [URL] = []
        for id in ids.sorted() where ModelPin.identifier(id) {
            let model = models.appendingPathComponent(id,isDirectory:true)
            guard ModelFiles.existingDirectory(model), let revisions = try? FileManager.default.contentsOfDirectory(atPath:model.path), revisions.count <= 1024 else { continue }
            for revision in revisions.sorted() where ModelPin.hash(revision) {
                let folder = model.appendingPathComponent(revision,isDirectory:true), notice = folder.appendingPathComponent("NOTICE.txt")
                guard ModelFiles.existingDirectory(folder), let size = try? ModelFiles.size(notice), size > 0, size <= 2 << 20 else { continue }
                output.append(notice)
            }
        }
        return output
    }
}
