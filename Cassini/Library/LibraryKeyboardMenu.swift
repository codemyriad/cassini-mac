// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import CassiniLibrary

/// SwiftUI's row context menu covers pointer/VoiceOver activation. Explicit
/// Menu and Shift-F10 support also places the menu at the selected list row.
@MainActor enum LibraryKeyboardMenu {
    static weak var anchor: NSView?
    private final class Action: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func perform(_ sender: Any?) { action() }
    }
    static func show(_ meeting: LibraryMeeting, trash: MeetingTrashCoordinator, undo: UndoManager?) -> Bool {
        guard let view = anchor, view.window === NSApp.keyWindow else { return false }
        let export = Action { MeetingExportCoordinator.shared.show(meeting) }
        let remove = Action { trash.move(meeting,undoManager:undo) }
        let menu = NSMenu(); menu.autoenablesItems = false
        let exportItem = NSMenuItem(title:UXText.text("common.exportEllipsis"),action:#selector(Action.perform(_:)),keyEquivalent:"")
        exportItem.target = export; exportItem.isEnabled = MeetingExportCoordinator.canExport(meeting); menu.addItem(exportItem)
        if trash.canTrash(meeting) {
            menu.addItem(.separator())
            let removeItem = NSMenuItem(title:UXText.text("common.moveToTrash"),action:#selector(Action.perform(_:)),keyEquivalent:"")
            removeItem.identifier = NSUserInterfaceItemIdentifier("library-keyboard-trash")
            removeItem.setAccessibilityIdentifier("library-keyboard-trash")
            removeItem.target = remove; menu.addItem(removeItem)
        }
        let rect = view.bounds
        withExtendedLifetime((export,remove)) {
            menu.popUp(positioning:nil,at:NSPoint(x:rect.minX + 16,y:rect.maxY),in:view)
        }
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
