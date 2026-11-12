// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Presentation only. No LibraryView/Meeting adapter, state owner, catalog I/O,
/// timer, focus or interaction policy; the host supplies the projected value.
struct CatalogStatusBadge: View {
    let presentation: CatalogBadgePresentation?
    var isAnimating = true

    var body: some View {
        if let presentation, let kind = Self.visualKind(presentation.kind) {
            MeetingStatusBadge(kind: kind, label: presentation.text, isAnimating: isAnimating)
        }
    }

    static func visualKind(_ modelKind: String) -> StatusBadgeKind? {
        StatusBadgeKind(rawValue: modelKind == "needsAttention" ? "attention" : modelKind)
    }
}
