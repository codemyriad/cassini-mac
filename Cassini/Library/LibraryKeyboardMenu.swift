// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniLibrary

/// SwiftUI's row context menu covers pointer/VoiceOver activation. Explicit
/// Menu and Shift-F10 support also places the menu at the selected list row.
@MainActor enum LibraryKeyboardMenu {
    private final class Action: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func perform(_ sender: Any?) { action() }
    }
    static func show(_ meeting: LibraryMeeting, trash: MeetingTrashCoordinator, undo: UndoManager?) -> Bool {
        func selectedTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.selectedRow >= 0 { return table }
            return view.subviews.compactMap { selectedTable($0) }.first
        }
        guard let view = NSApp.keyWindow?.contentView, let table = selectedTable(view) else { return false }
        let export = Action { MeetingExportCoordinator.shared.show(meeting) }
        let remove = Action { trash.move(meeting,undoManager:undo) }
        let menu = NSMenu(); menu.autoenablesItems = false
        let exportItem = NSMenuItem(title:UXText.text("common.exportEllipsis"),action:#selector(Action.perform(_:)),keyEquivalent:"")
        exportItem.target = export; exportItem.isEnabled = MeetingExportCoordinator.canExport(meeting); menu.addItem(exportItem)
        if trash.canTrash(meeting) {
            menu.addItem(.separator())
            let removeItem = NSMenuItem(title:UXText.text("common.moveToTrash"),action:#selector(Action.perform(_:)),keyEquivalent:"")
            removeItem.target = remove; menu.addItem(removeItem)
        }
        let rect = table.rect(ofRow:table.selectedRow)
        withExtendedLifetime((export,remove)) {
            menu.popUp(positioning:nil,at:NSPoint(x:rect.minX + 16,y:rect.maxY),in:table)
        }
        return true
    }
}
