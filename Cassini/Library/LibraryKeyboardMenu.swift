// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import CassiniLibrary

/// SwiftUI's row context menu covers pointer/VoiceOver activation. Explicit
/// Menu and Shift-F10 support also places the menu at the selected list row.
@MainActor enum LibraryKeyboardMenu {
    static weak var anchor: NSView?
    private final class ActionItem: NSMenuItem {
        private let handler: () -> Void
        init(title: String, handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title:title,action:nil,keyEquivalent:"")
            target = self; action = #selector(invoke(_:))
        }
        @available(*,unavailable) required init(coder: NSCoder) { fatalError("Programmatic menu item") }
        @objc private func invoke(_ sender: Any?) {
            // The item owns its action, including AppKit's deferred delivery.
            // Leave native tracking/the intercepted key event before showing UI.
            DispatchQueue.main.async { [handler] in handler() }
        }
    }
    static func show(_ meeting: LibraryMeeting, trash: MeetingTrashCoordinator, undo: UndoManager?) -> Bool {
        guard let view = anchor, view.window === NSApp.keyWindow else { return false }
        let menu = NSMenu(); menu.autoenablesItems = false
        let renameItem = ActionItem(title:UXText.text("meeting.renameEllipsis")) { MeetingRenameCoordinator.shared.show(meeting) }
        renameItem.isEnabled = MeetingRenameCoordinator.shared.canRename(meeting)
        renameItem.setAccessibilityIdentifier("library-keyboard-rename"); menu.addItem(renameItem)
        let exportItem = ActionItem(title:UXText.text("common.exportEllipsis")) { MeetingExportCoordinator.shared.show(meeting) }
        exportItem.isEnabled = MeetingExportCoordinator.canExport(meeting); menu.addItem(exportItem)
        if trash.canTrash(meeting) {
            menu.addItem(.separator())
            let removeItem = ActionItem(title:UXText.text("common.moveToTrash")) { trash.move(meeting,undoManager:undo) }
            removeItem.identifier = NSUserInterfaceItemIdentifier("library-keyboard-trash")
            removeItem.setAccessibilityIdentifier("library-keyboard-trash")
            menu.addItem(removeItem)
        }
        let rect = view.bounds
        menu.popUp(positioning:nil,at:NSPoint(x:rect.minX + 16,y:rect.maxY),in:view)
        return true
    }
}

/// A concrete row anchor avoids depending on SwiftUI's private List view class.
struct LibraryMenuAnchor: NSViewRepresentable {
    final class View: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
    func makeNSView(context: Context) -> View { let view = View(); LibraryKeyboardMenu.anchor = view; return view }
    func updateNSView(_ view: View, context: Context) { LibraryKeyboardMenu.anchor = view }
    static func dismantleNSView(_ view: View, coordinator: ()) {
        if LibraryKeyboardMenu.anchor === view { LibraryKeyboardMenu.anchor = nil }
    }
}
