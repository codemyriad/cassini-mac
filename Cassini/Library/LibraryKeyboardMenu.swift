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
        guard MeetingRenameCoordinator.shared.presentation != .speakers,
              let view = anchor,
              let window = view.window,
              window === NSApp.keyWindow,
              window.attachedSheet == nil,
              NSApp.modalWindow == nil else { return false }
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

/// Observe Cassini's own double-click, right-click / Control-click, and VoiceOver
/// Show Menu (`AXShowMenu`) inside the visible card row, and remove NSTableView's
/// extra horizontal row inset and system highlights (D-1198 items 3, 12).
struct LibraryRowOpenAnchor: NSViewRepresentable {
    let rowKey: String
    let open: () -> Void
    var isEnabled: Bool = true
    var menuAccessibilityLabel: String = ""
    var menuAccessibilityIdentifier: String = ""
    var buildContextMenu: (() -> NSMenu)? = nil
    var onContextMenuOpenChanged: ((Bool) -> Void)? = nil

    @MainActor private final class WeakView {
        weak var value: View?
        init(_ value: View) { self.value = value }
    }
    @MainActor private static var anchorsByKey: [String: WeakView] = [:]

    @MainActor @discardableResult
    static func performShowMenu(forKey rowKey: String) -> Bool {
        guard let view = anchorsByKey[rowKey]?.value else { return false }
        return view.accessibilityPerformShowMenu()
    }

    final class View: NSView {
        private final class Monitor: @unchecked Sendable {
            let value: Any
            init(_ value: Any) { self.value = value }
        }
        var rowKey: String?
        var open: (() -> Void)?
        var isInteractionEnabled = true
        var menuAccessibilityLabel = ""
        var menuAccessibilityIdentifier = ""
        var buildContextMenu: (() -> NSMenu)?
        var onContextMenuOpenChanged: ((Bool) -> Void)?
        private var monitor: Monitor?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool {
            buildContextMenu != nil
                && isInteractionEnabled
                && MeetingRenameCoordinator.shared.presentation != .speakers
        }
        override func accessibilityRole() -> NSAccessibility.Role? { .group }
        override func accessibilityLabel() -> String? {
            menuAccessibilityLabel.isEmpty ? nil : menuAccessibilityLabel
        }
        override func accessibilityIdentifier() -> String {
            menuAccessibilityIdentifier
        }
        override func accessibilityPerformShowMenu() -> Bool {
            guard canAcceptInteraction(atWindowPoint: nil), buildContextMenu != nil else { return false }
            let point = NSPoint(x: bounds.midX, y: bounds.midY)
            return presentContextMenu(at: point, windowPoint: nil)
        }
        func enclosingTableRowView() -> NSTableRowView? {
            var node = superview
            while let view = node {
                if let row = view as? NSTableRowView { return row }
                node = view.superview
            }
            return nil
        }
        func isHitTarget(atWindowPoint locationInWindow: NSPoint) -> Bool {
            guard let window, let contentView = window.contentView else { return false }
            let contentPoint = contentView.superview?.convert(locationInWindow, from: nil) ?? locationInWindow
            guard let hitView = contentView.hitTest(contentPoint) else { return false }
            if let rowView = enclosingTableRowView() {
                return hitView === rowView || hitView.isDescendant(of: rowView)
            }
            guard let container = superview else { return hitView === self }
            return hitView === container || hitView.isDescendant(of: container)
        }
        func canAcceptInteraction(atWindowPoint locationInWindow: NSPoint? = nil) -> Bool {
            guard isInteractionEnabled,
                  MeetingRenameCoordinator.shared.presentation != .speakers,
                  let window,
                  window.isVisible,
                  window.attachedSheet == nil,
                  NSApp.modalWindow == nil,
                  !isHiddenOrHasHiddenAncestor else {
                return false
            }
            if let locationInWindow {
                let point = convert(locationInWindow, from: nil)
                guard visibleRect.contains(point),
                      isHitTarget(atWindowPoint: locationInWindow) else {
                    return false
                }
            }
            return true
        }
        @discardableResult
        func presentContextMenu(at point: NSPoint, windowPoint: NSPoint?) -> Bool {
            guard canAcceptInteraction(atWindowPoint: windowPoint),
                  buildContextMenu != nil else {
                return false
            }
            onContextMenuOpenChanged?(true)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.canAcceptInteraction(atWindowPoint: windowPoint),
                      let currentBuildMenu = self.buildContextMenu else {
                    self?.onContextMenuOpenChanged?(false)
                    return
                }
                let menu = currentBuildMenu()
                let delegate = LibraryContextMenuDelegate { [weak self] in
                    self?.onContextMenuOpenChanged?(false)
                }
                menu.delegate = delegate
                withExtendedLifetime(delegate) {
                    menu.popUp(positioning: nil, at: point, in: self)
                }
                delegate.finish()
            }
            return true
        }
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
                    var needsColumnResize = false
                    if let scrollView = table.enclosingScrollView, scrollView.scrollerStyle != .overlay {
                        scrollView.scrollerStyle = .overlay
                        needsColumnResize = true
                    }
                    if table.selectionHighlightStyle != .none {
                        table.selectionHighlightStyle = .none
                    }
                    if table.style != .fullWidth {
                        table.style = .fullWidth
                        needsColumnResize = true
                    }
                    if table.intercellSpacing != .zero {
                        table.intercellSpacing = .zero
                        needsColumnResize = true
                    }
                    if let outline = table as? NSOutlineView, outline.indentationPerLevel != 0 {
                        outline.indentationPerLevel = 0
                        needsColumnResize = true
                    }
                    if needsColumnResize {
                        table.sizeLastColumnToFit()
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
                    guard let self,
                          event.window === self.window,
                          self.canAcceptInteraction(atWindowPoint: event.locationInWindow) else {
                        return event
                    }
                    let point = self.convert(event.locationInWindow, from: nil)

                    let isContextClick = event.type == .rightMouseDown
                        || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
                    if isContextClick, self.buildContextMenu != nil {
                        self.presentContextMenu(at: point, windowPoint: event.locationInWindow)
                        return nil
                    }

                    guard event.type == .leftMouseDown, event.clickCount == 2 else { return event }
                    let windowPoint = event.locationInWindow
                    // Default mode runs after native mouse tracking returns.
                    RunLoop.main.perform(inModes: [.default]) { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, self.canAcceptInteraction(atWindowPoint: windowPoint) else { return }
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
        if let oldKey = view.rowKey, oldKey != rowKey,
           Self.anchorsByKey[oldKey]?.value === view {
            Self.anchorsByKey.removeValue(forKey: oldKey)
        }
        view.rowKey = rowKey
        Self.anchorsByKey[rowKey] = WeakView(view)
        view.open = open
        view.isInteractionEnabled = isEnabled && context.environment.isEnabled
        view.menuAccessibilityLabel = menuAccessibilityLabel
        view.menuAccessibilityIdentifier = menuAccessibilityIdentifier
        view.setAccessibilityIdentifier(menuAccessibilityIdentifier)
        view.buildContextMenu = buildContextMenu
        view.onContextMenuOpenChanged = onContextMenuOpenChanged
        view.suppressSystemRowHighlight()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: View, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    static func dismantleNSView(_ view: View, coordinator: ()) {
        if let key = view.rowKey, Self.anchorsByKey[key]?.value === view {
            Self.anchorsByKey.removeValue(forKey: key)
        }
        view.stopMonitoring()
        view.rowKey = nil
        view.open = nil
        view.buildContextMenu = nil
        view.onContextMenuOpenChanged = nil
    }
}
