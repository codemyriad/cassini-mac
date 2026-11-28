// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import CassiniLibrary

/// SwiftUI's row context menu covers pointer/VoiceOver activation. Explicit
/// Menu and Shift-F10 support also places the menu at the selected list row.
@MainActor enum LibraryKeyboardMenu {
    static weak var anchor: NSView?
    static func focusList() {
        let document = anchor?.enclosingScrollView?.documentView
        var view = anchor
        while let current = view {
            if current is NSTableView || current === document,
               current.window?.makeFirstResponder(current) == true {
                return
            }
            view = current.superview
        }
    }
    static func hasListFocus(in window: NSWindow) -> Bool {
        guard let document = anchor?.enclosingScrollView?.documentView,
              let responder = window.firstResponder as? NSView else { return false }
        return responder === document || responder.isDescendant(of: document)
    }
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
    static func buildContextMenu(
        for meeting: LibraryMeeting,
        trash: MeetingTrashCoordinator,
        undo: UndoManager?,
        forKeyboard: Bool
    ) -> NSMenu {
        let store = LibraryStore.shared
        let rename = MeetingRenameCoordinator.shared
        let dateTime = MeetingDateTimeCoordinator.shared
        let exporter = MeetingExportCoordinator.shared
        let bulkExporter = BulkZipExportCoordinator.shared
        let recordingDetails = RecordingDetailsCoordinator.shared
        let isMultiSelection = store.selectedKeys.count > 1 && store.selectedKeys.contains(meeting.libraryKey)

        let menu = NSMenu()
        menu.autoenablesItems = false

        let starItem = ActionItem(title: UXText.text(store.isStarred(meeting) ? "meeting.unstar" : "meeting.star")) {
            store.toggleStar(meeting)
        }
        starItem.setAccessibilityIdentifier(forKeyboard ? "library-keyboard-star" : "library-star")
        menu.addItem(starItem)

        let renameItem = ActionItem(title: UXText.text("meeting.renameEllipsis")) {
            store.selectedKey = meeting.libraryKey
            rename.show(meeting)
        }
        renameItem.isEnabled = !isMultiSelection && rename.canRename(meeting)
        renameItem.setAccessibilityIdentifier(forKeyboard ? "library-keyboard-rename" : "library-rename")
        menu.addItem(renameItem)

        let dateTimeItem = ActionItem(title: UXText.text("meeting.setDateTimeEllipsis")) {
            store.selectedKey = meeting.libraryKey
            dateTime.show(meeting)
        }
        dateTimeItem.isEnabled = !isMultiSelection && dateTime.canSetDateTime(meeting)
        dateTimeItem.setAccessibilityIdentifier(forKeyboard ? "library-keyboard-set-date-time" : "library-set-date-time")
        menu.addItem(dateTimeItem)

        let exportItem = ActionItem(title: UXText.text("common.exportEllipsis")) {
            store.selectedKey = meeting.libraryKey
            exporter.show(meeting)
        }
        exportItem.isEnabled = !isMultiSelection && MeetingExportCoordinator.canExport(meeting)
        menu.addItem(exportItem)

        if isMultiSelection {
            let exportSelectedItem = ActionItem(title: UXText.text("export.zip.selected")) {
                bulkExporter.exportSelected()
            }
            exportSelectedItem.isEnabled = bulkExporter.canExportSelected
            exportSelectedItem.setAccessibilityIdentifier(forKeyboard ? "library-keyboard-export-selected-zip" : "library-export-selected-zip")
            menu.addItem(exportSelectedItem)
        }

        let detailsItem = ActionItem(title: UXText.text("details.menu")) {
            store.selectedKey = meeting.libraryKey
            recordingDetails.show(meeting)
        }
        detailsItem.isEnabled = !isMultiSelection
        detailsItem.setAccessibilityIdentifier(forKeyboard ? "library-keyboard-recording-details" : "library-recording-details")
        menu.addItem(detailsItem)

        if !isMultiSelection && trash.canTrash(meeting) {
            menu.addItem(.separator())
            let removeItem = ActionItem(title: UXText.text("common.moveToTrash")) {
                store.selectedKey = meeting.libraryKey
                trash.move(meeting, undoManager: undo ?? NSApp.keyWindow?.undoManager)
            }
            let trashId = forKeyboard ? "library-keyboard-trash" : "move-to-trash"
            removeItem.identifier = NSUserInterfaceItemIdentifier(trashId)
            removeItem.setAccessibilityIdentifier(trashId)
            menu.addItem(removeItem)
        }
        return menu
    }

    static func show(_ meeting: LibraryMeeting?, trash: MeetingTrashCoordinator, undo: UndoManager?) -> Bool {
        guard let view = anchor, view.window === NSApp.keyWindow else { return false }
        let menu: NSMenu
        if let meeting {
            menu = buildContextMenu(for: meeting, trash: trash, undo: undo, forKeyboard: true)
        } else {
            menu = NSMenu()
            menu.autoenablesItems = false
            let renameItem = ActionItem(title: UXText.text("meeting.renameEllipsis")) {}
            renameItem.isEnabled = false
            renameItem.setAccessibilityIdentifier("library-keyboard-rename")
            menu.addItem(renameItem)
            let dateTimeItem = ActionItem(title: UXText.text("meeting.setDateTimeEllipsis")) {}
            dateTimeItem.isEnabled = false
            dateTimeItem.setAccessibilityIdentifier("library-keyboard-set-date-time")
            menu.addItem(dateTimeItem)
            let exportItem = ActionItem(title: UXText.text("common.exportEllipsis")) {}
            exportItem.isEnabled = false
            menu.addItem(exportItem)
            if LibraryStore.shared.selectedKeys.count > 1 {
                let exportSelectedItem = ActionItem(title: UXText.text("export.zip.selected")) {
                    BulkZipExportCoordinator.shared.exportSelected()
                }
                exportSelectedItem.isEnabled = BulkZipExportCoordinator.shared.canExportSelected
                exportSelectedItem.setAccessibilityIdentifier("library-keyboard-export-selected-zip")
                menu.addItem(exportSelectedItem)
            }
            let detailsItem = ActionItem(title: UXText.text("details.menu")) {}
            detailsItem.isEnabled = false
            detailsItem.setAccessibilityIdentifier("library-keyboard-recording-details")
            menu.addItem(detailsItem)
        }
        let rect = view.bounds
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX + 16, y: rect.maxY), in: view)
        return true
    }
}

/// Tracks NSMenu end-of-tracking so the card's context-menu ring always clears on Esc,
/// click away, or item selection (D-1198 item 12).
@MainActor final class LibraryContextMenuDelegate: NSObject, NSMenuDelegate {
    private let onClose: () -> Void
    private var didClose = false

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func menuDidClose(_ menu: NSMenu) {
        finish()
    }

    func finish() {
        guard !didClose else { return }
        didClose = true
        onClose()
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

/// Observe Cassini's own double-click and right-click inside the visible card row,
/// and remove NSTableView's extra horizontal row inset and system highlights (D-1198 items 3, 12).
struct LibraryRowOpenAnchor: NSViewRepresentable {
    let open: () -> Void
    var buildContextMenu: (() -> NSMenu)? = nil
    var onContextMenuOpenChanged: ((Bool) -> Void)? = nil
    final class View: NSView {
        private final class Monitor: @unchecked Sendable {
            let value: Any
            init(_ value: Any) { self.value = value }
        }
        var open: (() -> Void)?
        var buildContextMenu: (() -> NSMenu)?
        var onContextMenuOpenChanged: ((Bool) -> Void)?
        private var monitor: Monitor?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func suppressSystemRowHighlight() {
            var node = superview
            while let view = node {
                if let row = view as? NSTableRowView {
                    if row.selectionHighlightStyle != .none {
                        row.selectionHighlightStyle = .none
                    }
                    if row.isEmphasized {
                        row.isEmphasized = false
                    }
                }
                if let table = view as? NSTableView {
                    if table.selectionHighlightStyle != .none {
                        table.selectionHighlightStyle = .none
                    }
                    if table.style != .fullWidth {
                        table.style = .fullWidth
                    }
                    if table.intercellSpacing != .zero {
                        table.intercellSpacing = .zero
                    }
                    if let outline = table as? NSOutlineView, outline.indentationPerLevel != 0 {
                        outline.indentationPerLevel = 0
                    }
                }
                node = view.superview
            }
        }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview(); suppressSystemRowHighlight()
        }
        override func layout() {
            super.layout(); suppressSystemRowHighlight()
        }
        override func viewWillDraw() {
            super.viewWillDraw(); suppressSystemRowHighlight()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); suppressSystemRowHighlight(); stopMonitoring()
            guard window != nil else { return }
            monitor = Monitor(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.window === self.window,
                          self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor else { return event }
                    let point = self.convert(event.locationInWindow, from: nil)
                    guard self.visibleRect.contains(point) else { return event }

                    let isContextClick = event.type == .rightMouseDown
                        || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
                    if isContextClick, let buildMenu = self.buildContextMenu {
                        self.onContextMenuOpenChanged?(true)
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.window?.isVisible == true else {
                                self?.onContextMenuOpenChanged?(false)
                                return
                            }
                            let menu = buildMenu()
                            let delegate = LibraryContextMenuDelegate { [weak self] in
                                self?.onContextMenuOpenChanged?(false)
                            }
                            menu.delegate = delegate
                            withExtendedLifetime(delegate) {
                                menu.popUp(positioning: nil, at: point, in: self)
                            }
                            delegate.finish()
                        }
                        return nil
                    }

                    guard event.type == .leftMouseDown, event.clickCount == 2 else { return event }
                    // Default mode runs after native mouse tracking returns.
                    RunLoop.main.perform(inModes: [.default]) { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, self.window?.isVisible == true else { return }
                            self.open?()
                        }
                    }
                    return event
                }
            }!)
        }
        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor.value) }; monitor = nil
        }
        deinit {
            if let monitor { DispatchQueue.main.async { NSEvent.removeMonitor(monitor.value) } }
        }
    }
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ view: View, context: Context) {
        view.open = open
        view.buildContextMenu = buildContextMenu
        view.onContextMenuOpenChanged = onContextMenuOpenChanged
        view.suppressSystemRowHighlight()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: View, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    static func dismantleNSView(_ view: View, coordinator: ()) {
        view.stopMonitoring()
        view.open = nil
        view.buildContextMenu = nil
        view.onContextMenuOpenChanged = nil
    }
}
