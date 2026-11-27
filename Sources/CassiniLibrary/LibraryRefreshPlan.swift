// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct LibraryRefreshTarget: Sendable, Equatable {
    public let root: URL
    public let affected: URL?

    public init(root: URL, affected: URL?) {
        self.root = root
        self.affected = affected
    }
}

/// Resolves symlinked targets and selects affected Library roots off the main actor.
public enum LibraryRefreshPlan {
    public static func selectTargets(
        target: URL,
        primaryRoot: URL,
        roots: [URL],
        canonicalize: (URL) -> URL = LibraryLocation.canonical
    ) -> [LibraryRefreshTarget] {
        if target == primaryRoot {
            return roots.map { LibraryRefreshTarget(root: $0, affected: nil) }
        }
        let canonicalTarget = canonicalize(target)
        let canonicalParent = canonicalize(target.deletingLastPathComponent())
        for root in roots {
            let canonicalRoot = canonicalize(root)
            if canonicalTarget.path == canonicalRoot.path {
                return [LibraryRefreshTarget(root: root, affected: nil)]
            }
            if canonicalParent.path == canonicalRoot.path {
                return [LibraryRefreshTarget(root: root, affected: root.appendingPathComponent(target.lastPathComponent))]
            }
        }
        return []
    }
}
