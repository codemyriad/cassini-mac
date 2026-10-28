// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum ModelStorage {
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
