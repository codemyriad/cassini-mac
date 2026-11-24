// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// Native groups expose one action each, avoiding SwiftUI toolbar wrappers that
/// duplicate their child button's role and identifier in the accessibility tree.
struct LibraryToolbarAction: NSViewRepresentable {
    enum Style: Equatable { case back, record, stop, saving, capsule, bordered, more }
    let title: String, label: String, identifier: String
    let style: Style
    var enabled = true
    var menu: (() -> NSMenu)? = nil
    #if DEBUG
    var fixtureOnLaidOut: ((String) -> Void)? = nil
    #endif
    let action: () -> Void
    func makeNSView(context: Context) -> LibraryToolbarActionView { LibraryToolbarActionView() }
    func updateNSView(_ view: LibraryToolbarActionView, context: Context) {
        var effective=self
        effective.enabled = enabled && MeetingRenameCoordinator.shared.presentation != .speakers
        view.update(effective)
    }
    struct MenuEntry {
        let title: String, identifier: String
        var enabled = true
        let action: () -> Void
    }
    static func menu(_ entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for entry in entries {
            let item = ActionItem(title:entry.title,handler:entry.action)
            item.isEnabled = entry.enabled; item.setAccessibilityIdentifier(entry.identifier); menu.addItem(item)
        }
        return menu
    }
    /// Intrinsic width of a toolbar action; shared with layout code that must
    /// reserve room for these buttons before AppKit lays them out.
    static func width(title: String, style: Style) -> CGFloat {
        switch style {
        case .back, .more: return 28
        default:
            let text = ceil((title as NSString).size(withAttributes:[.font:font]).width)
            return text + 28 + (style == .record ? 18 : style == .saving ? 22 : 0)
        }
    }
    static let font = NSFont.systemFont(ofSize:13,weight:.semibold)
    private final class ActionItem: NSMenuItem {
        private let handler: () -> Void
        init(title: String, handler: @escaping () -> Void) {
            self.handler = handler; super.init(title:title,action:nil,keyEquivalent:"")
            target = self; action = #selector(invoke(_:))
        }
        required init(coder: NSCoder) { fatalError("Programmatic menu item") }
        @objc private func invoke(_ sender: Any?) { DispatchQueue.main.async { [handler] in handler() } }
    }
}
final class LibraryToolbarActionView: NSView {
    private final class ActionButton: NSButton {
        var spokenLabel = ""
        override func accessibilityLabel() -> String? { spokenLabel }
    }
    private let button = ActionButton()
    private let spinner: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning; indicator.controlSize = .small
        indicator.isDisplayedWhenStopped = false; indicator.isHidden = true
        indicator.setAccessibilityElement(false)
        return indicator
    }()
    private var action: (() -> Void)?, makeMenu: (() -> NSMenu)?
    private var currentStyle: LibraryToolbarAction.Style = .bordered
    #if DEBUG
    private var fixtureOnLaidOut: ((String) -> Void)?
    #endif
    private var size = NSSize(width:28,height:34)
    override init(frame: NSRect) {
        super.init(frame:frame)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        button.target = self; button.action = #selector(invoke(_:))
        button.setButtonType(.momentaryPushIn); button.wantsLayer = true; button.layer?.cornerRadius = 6
        addSubview(button); addSubview(spinner); setAccessibilityChildren([button])
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { size }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        #if DEBUG
        scheduleFixtureLayoutNotification()
        #endif
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyLayerFill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyLayerFill() }
    private func applyLayerFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let disabledRecord = currentStyle == .record && !button.isEnabled
            let fill: NSColor = disabledRecord ? CassiniTheme.nsChipFill : [.stop,.record].contains(currentStyle) ? CassiniTheme.nsRecord : [.saving,.capsule].contains(currentStyle) ? CassiniTheme.nsChipFill : .clear
            button.layer?.backgroundColor = fill.cgColor
        }
    }
    override func layout() {
        super.layout(); button.frame = bounds
        spinner.frame = NSRect(x:10,y:(bounds.height - 16) / 2,width:16,height:16)
        #if DEBUG
        if superview != nil, button.frame.width > 0 {
            fixtureOnLaidOut?(button.accessibilityIdentifier())
        }
        #endif
    }
    func update(_ value: LibraryToolbarAction) {
        action = value.action; makeMenu = value.menu; currentStyle = value.style
        #if DEBUG
        fixtureOnLaidOut = value.fixtureOnLaidOut
        #endif
        // SwiftUI otherwise borrows the only child's identifier/label for its
        // representable proxy. Keep the container distinct from the action.
        setAccessibilityIdentifier(value.identifier + "-group"); setAccessibilityLabel("")
        button.spokenLabel = value.label; button.setAccessibilityIdentifier(value.identifier)
        button.toolTip = value.label; button.isEnabled = value.enabled
        let font = LibraryToolbarAction.font
        button.font = font; button.image = nil
        button.isBordered = value.style == .bordered; button.bezelStyle = .rounded
        button.layer?.cornerRadius = [.record,.stop,.saving,.capsule].contains(value.style) ? 17 : 6
        button.imagePosition = .imageLeft
        let disabledRecord = value.style == .record && !value.enabled
        let tint: NSColor = disabledRecord ? CassiniTheme.nsInk3 : [.stop,.record].contains(value.style) ? CassiniTheme.nsOnRecord : value.style == .saving ? CassiniTheme.nsInk2 : CassiniTheme.nsInk
        button.attributedTitle = NSAttributedString(string:value.title,attributes:[.font:font,.foregroundColor:tint])
        applyLayerFill()
        size = NSSize(width:LibraryToolbarAction.width(title:value.title,style:value.style),height:34)
        if value.style == .saving { spinner.isHidden = false; spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil); spinner.isHidden = true }
        switch value.style {
        case .back, .more:
            button.image = NSImage(systemSymbolName:value.style == .back ? "chevron.left" : "ellipsis",accessibilityDescription:nil)
            button.imagePosition = .imageOnly; button.contentTintColor = CassiniTheme.nsInk
        case .record:
            let dot = value.enabled ? CassiniTheme.nsOnRecord : CassiniTheme.nsInk3
            button.image = NSImage(size:NSSize(width:18,height:10),flipped:false) { _ in
                dot.setFill(); NSBezierPath(ovalIn:NSRect(x:0,y:0,width:10,height:10)).fill(); return true
            }
            button.imageHugsTitle = true
        case .saving:
            button.image = NSImage(size:NSSize(width:22,height:16))
            button.imageHugsTitle = true
        default: break
        }
        needsLayout = true; invalidateIntrinsicContentSize()
        #if DEBUG
        scheduleFixtureLayoutNotification()
        #endif
    }
    #if DEBUG
    private func scheduleFixtureLayoutNotification() {
        guard fixtureOnLaidOut != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, let callback = self.fixtureOnLaidOut, self.superview != nil else { return }
            var root: NSView = self
            while let parent = root.superview { root = parent }
            if self.needsLayout || self.button.frame.width == 0 {
                root.layoutSubtreeIfNeeded()
            } else {
                callback(self.button.accessibilityIdentifier())
            }
        }
    }
    #endif
    @objc private func invoke(_ sender: Any?) {
        guard MeetingRenameCoordinator.shared.presentation != .speakers else {return}
        if let makeMenu { makeMenu().popUp(positioning:nil,at:NSPoint(x:0,y:0),in:self) }
        else { action?() }
    }
}

