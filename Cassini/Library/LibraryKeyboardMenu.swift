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

/// Observe only Cassini's own second mouse-down inside the visible row. This
/// leaves List selection and its independently working context menus intact.
struct LibraryRowOpenAnchor: NSViewRepresentable {
    let open: () -> Void
    final class View: NSView {
        private final class Monitor: @unchecked Sendable {
            let value: Any
            init(_ value: Any) { self.value = value }
        }
        var open: (() -> Void)?
        private var monitor: Monitor?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stopMonitoring()
            guard window != nil else { return }
            monitor = Monitor(NSEvent.addLocalMonitorForEvents(matching:.leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.clickCount == 2, event.window === self.window,
                          self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor else { return event }
                    let point = self.convert(event.locationInWindow,from:nil)
                    let inside = self.visibleRect.contains(point)
                    guard inside else { return event }
                    // Default mode runs after native mouse tracking returns.
                    RunLoop.main.perform(inModes:[.default]) { [weak self] in
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
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: View, context: Context) -> CGSize? {
        CGSize(width:proposal.width ?? 0,height:proposal.height ?? 0)
    }
    static func dismantleNSView(_ view: View, coordinator: ()) { view.stopMonitoring(); view.open = nil }
}
