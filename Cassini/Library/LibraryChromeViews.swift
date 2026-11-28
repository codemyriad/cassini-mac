// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ObjectiveC
import SwiftUI
import CassiniLibrary

struct LibraryWindowTitleModifier: ViewModifier {
    let savedDetail: MeetingDetailModel?
    let showsFirstRun: Bool
    let searchVisible: Bool
    let format: LibraryFormat

    func body(content: Content) -> some View {
        let title: String
        let subtitle: String
        if let detail = savedDetail, !showsFirstRun, !searchVisible {
            title = detail.meeting.title ?? UXText.text("library.untitled")
            subtitle = format.previewSubtitle(
                detail.meeting.meetingTime,
                durationMs: detail.meeting.durationMs,
                received: detail.meeting.state.origin == .received,
                transcribedOnAnotherDevice: detail.meeting.transcribedOnAnotherDevice
            )
        } else {
            title = UXText.text("app.name")
            subtitle = ""
        }
        return content
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar(removing: .title)
    }
}

/// Custom All / Starred segmented control (D-1197 item 4, L-107):
/// capsule track (ink at 6%, 2 pt padding), selected white/elevated capsule (22 pt tall,
/// 14 pt horizontal padding, 12 pt medium text, soft shadow and hairline), plain ink unselected.
/// Identical appearance in active and inactive windows; exposed as a single-choice radio group
/// for VoiceOver and arrow keys.
struct LibraryFilterSegmentedControl: NSViewRepresentable {
    @Binding var selection: LibraryPreferences.Filter

    func makeNSView(context: Context) -> FilterSegmentedView {
        let view = FilterSegmentedView()
        view.selection = selection
        view.onSelect = { newValue in
            selection = newValue
        }
        return view
    }

    func updateNSView(_ nsView: FilterSegmentedView, context: Context) {
        nsView.onSelect = { newValue in
            selection = newValue
        }
        nsView.update(selection: selection)
    }

    final class FilterSegmentedView: NSView {
        private static let segmentHeight: CGFloat = 22
        private static let trackPadding: CGFloat = 2
        private static let horizontalTextPadding: CGFloat = 14
        private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        private static let darkSelectedFill: NSColor = {
            let base = CassiniTokens.surfaceEntry.resolvedNSColor(dark: true)
            let lift = CassiniTokens.inkEntry.resolvedNSColor(dark: true)
            return base.blended(withFraction: 0.18, of: lift) ?? CassiniTokens.raisedEntry.resolvedNSColor(dark: true)
        }()
        private static let lightSelectedFill = CassiniTokens.surfaceEntry.resolvedNSColor(dark: false)

        var selection: LibraryPreferences.Filter = .all
        var onSelect: ((LibraryPreferences.Filter) -> Void)?

        private var allTitle: String { UXText.text("library.filter.all") }
        private var starredTitle: String { UXText.text("library.filter.starred") }
        private lazy var allAccessibilityElement = FilterSegmentAccessibilityElement(parent: self, filter: .all)
        private lazy var starredAccessibilityElement = FilterSegmentAccessibilityElement(parent: self, filter: .starred)

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(true)
            setAccessibilityRole(.radioGroup)
            setAccessibilityIdentifier("library-filters")
            setAccessibilityLabel(UXText.text("library.filters.a11y"))
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        func update(selection newSelection: LibraryPreferences.Filter) {
            let changed = selection != newSelection
            selection = newSelection
            setAccessibilityLabel(UXText.text("library.filters.a11y"))
            allAccessibilityElement.refreshTitles()
            starredAccessibilityElement.refreshTitles()
            invalidateIntrinsicContentSize()
            needsDisplay = true
            if changed {
                NSAccessibility.post(element: self, notification: .valueChanged)
            }
        }

        private func segmentWidth(for title: String) -> CGFloat {
            let textSize = (title as NSString).size(withAttributes: [.font: Self.font])
            return ceil(textSize.width) + Self.horizontalTextPadding * 2
        }

        private func segmentRects() -> (all: NSRect, starred: NSRect) {
            let pad = Self.trackPadding
            let h = Self.segmentHeight
            let allW = segmentWidth(for: allTitle)
            let starredW = segmentWidth(for: starredTitle)
            let allRect = NSRect(x: pad, y: pad, width: allW, height: h)
            let starredRect = NSRect(x: allRect.maxX, y: pad, width: starredW, height: h)
            return (allRect, starredRect)
        }

        override var intrinsicContentSize: NSSize {
            let rects = segmentRects()
            return NSSize(
                width: rects.starred.maxX + Self.trackPadding,
                height: Self.segmentHeight + Self.trackPadding * 2
            )
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let trackRect = NSRect(origin: .zero, size: intrinsicContentSize)
            let trackRadius = trackRect.height / 2

            // Capsule track: ink at 6%
            let trackColor = CassiniTokens.inkEntry.resolvedNSColor(dark: isDark).withAlphaComponent(0.06)
            trackColor.setFill()
            NSBezierPath(roundedRect: trackRect, xRadius: trackRadius, yRadius: trackRadius).fill()

            let rects = segmentRects()
            let selectedRect = selection == .all ? rects.all : rects.starred
            let capsuleRadius = selectedRect.height / 2

            // Selected capsule with soft shadow and 0.5 pt hairline
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = CassiniTokens.shadowEntry.resolvedNSColor(dark: isDark)
            shadow.shadowBlurRadius = 1.5
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.set()
            let selectedFill = isDark ? Self.darkSelectedFill : Self.lightSelectedFill
            selectedFill.setFill()
            NSBezierPath(roundedRect: selectedRect, xRadius: capsuleRadius, yRadius: capsuleRadius).fill()
            NSGraphicsContext.restoreGraphicsState()

            let hairlineColor = CassiniTokens.lineEntry.resolvedNSColor(dark: isDark)
            hairlineColor.setStroke()
            let strokePath = NSBezierPath(
                roundedRect: selectedRect.insetBy(dx: 0.25, dy: 0.25),
                xRadius: max(0, capsuleRadius - 0.25),
                yRadius: max(0, capsuleRadius - 0.25)
            )
            strokePath.lineWidth = 0.5
            strokePath.stroke()

            let inkColor = CassiniTokens.inkEntry.resolvedNSColor(dark: isDark)
            drawLabel(allTitle, in: rects.all, color: inkColor)
            drawLabel(starredTitle, in: rects.starred, color: inkColor)
        }

        private func drawLabel(_ title: String, in rect: NSRect, color: NSColor) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Self.font,
                .foregroundColor: color,
            ]
            let size = (title as NSString).size(withAttributes: attrs)
            let drawRect = NSRect(
                x: rect.minX + (rect.width - size.width) / 2,
                y: rect.minY + (rect.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
            (title as NSString).draw(in: drawRect, withAttributes: attrs)
        }

        func select(_ value: LibraryPreferences.Filter) {
            guard selection != value else { return }
            selection = value
            needsDisplay = true
            onSelect?(value)
            NSAccessibility.post(element: self, notification: .valueChanged)
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            let pt = convert(event.locationInWindow, from: nil)
            let rects = segmentRects()
            if rects.all.contains(pt) {
                select(.all)
            } else if rects.starred.contains(pt) {
                select(.starred)
            }
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123: // Left arrow
                select(.all)
            case 124: // Right arrow
                select(.starred)
            case 49, 36: // Space or Return
                select(selection == .all ? .starred : .all)
            default:
                super.keyDown(with: event)
            }
        }

        override func accessibilityChildren() -> [Any]? {
            allAccessibilityElement.refreshTitles()
            starredAccessibilityElement.refreshTitles()
            return [allAccessibilityElement, starredAccessibilityElement]
        }

        override func accessibilityHitTest(_ point: NSPoint) -> Any? {
            guard let window else { return super.accessibilityHitTest(point) }
            let windowPoint = window.convertPoint(fromScreen: point)
            let localPoint = convert(windowPoint, from: nil)
            let rects = segmentRects()
            if rects.all.contains(localPoint) {
                return allAccessibilityElement
            }
            if rects.starred.contains(localPoint) {
                return starredAccessibilityElement
            }
            return self
        }

        final class FilterSegmentAccessibilityElement: NSAccessibilityElement {
            weak var owner: FilterSegmentedView?
            let filter: LibraryPreferences.Filter

            init(parent: FilterSegmentedView, filter: LibraryPreferences.Filter) {
                self.owner = parent
                self.filter = filter
                super.init()
                setAccessibilityParent(parent)
                setAccessibilityRole(.radioButton)
                setAccessibilityEnabled(true)
                refreshTitles()
            }

            func refreshTitles() {
                let title = filter == .all ? UXText.text("library.filter.all") : UXText.text("library.filter.starred")
                setAccessibilityTitle(title)
                setAccessibilityLabel(title)
            }

            override func accessibilityFrame() -> NSRect {
                guard let owner, let window = owner.window else { return .zero }
                let rects = owner.segmentRects()
                let localRect = filter == .all ? rects.all : rects.starred
                let inWindow = owner.convert(localRect, to: nil)
                return window.convertToScreen(inWindow)
            }

            override func accessibilityValue() -> Any? {
                NSNumber(value: owner?.selection == filter ? 1 : 0)
            }

            override func isAccessibilitySelected() -> Bool {
                owner?.selection == filter
            }

            override func accessibilityPerformPress() -> Bool {
                guard let owner else { return false }
                owner.window?.makeFirstResponder(owner)
                owner.select(filter)
                return true
            }
        }
    }
}

/// Window-wide click-away focus controller (D-1197 item 16, L-109):
/// clicking anywhere outside an actively edited text field ends editing by clearing the
/// window's first responder, while letting the click proceed normally to its target.
@MainActor final class WindowClickAwayFocusController {
    private static var associatedKey: UInt8 = 0
    private weak var window: NSWindow?
    private var monitor: Any?
    var onEndEditing: ((NSView) -> Void)?

    private init(window: NSWindow) {
        self.window = window
        installMonitor()
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    static func attach(to window: NSWindow, onEndEditing: @escaping (NSView) -> Void) {
        if let existing = objc_getAssociatedObject(window, &associatedKey) as? WindowClickAwayFocusController {
            existing.onEndEditing = onEndEditing
            return
        }
        let controller = WindowClickAwayFocusController(window: window)
        controller.onEndEditing = onEndEditing
        objc_setAssociatedObject(window, &associatedKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if let editingView = Self.activeEditingView(in: window) {
                let point = editingView.convert(event.locationInWindow, from: nil)
                if !editingView.bounds.contains(point) {
                    window.makeFirstResponder(nil)
                    self.onEndEditing?(editingView)
                }
            }
            return event
        }
    }

    private static func activeEditingView(in window: NSWindow) -> NSView? {
        guard let responder = window.firstResponder else { return nil }
        if let textView = responder as? NSTextView, textView.isFieldEditor {
            if let delegateView = textView.delegate as? NSView {
                return delegateView
            }
            return textView
        }
        if let field = responder as? NSTextField, field.isEditable {
            return field
        }
        return nil
    }
}

/// Inline-editable meeting title and subtitle hosted in the detail toolbar's
/// leading `.navigation` placement. Clicking the title edits in place and routes
/// commits through `MeetingRenameCoordinator.renameInline` on both macOS 15 and 26.
struct MeetingWindowTitleView: View {
    let title: String
    let subtitle: String
    let canRename: Bool
    var maxWidth: CGFloat = 280
    let onCommit: (String) -> Void
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            InlineEditableTitle(
                title: title,
                fontSize: 13,
                weight: .semibold,
                singleLine: true,
                canRename: canRename,
                identifier: "meeting-window-title",
                editorIdentifier: "meeting-window-title-editor",
                maxWidth: maxWidth,
                editing: $editing,
                onCommit: onCommit
            )
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(CassiniTheme.secondaryInk)
                .lineLimit(1)
                .accessibilityIdentifier("meeting-window-subtitle")
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .onChange(of: title) { _, _ in editing = false }
        .onChange(of: canRename) { _, allowed in if !allowed { editing = false } }
    }
}

struct SidebarGlassCircleModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .circle)
        } else {
            content.background(CassiniTheme.chipFill, in: Circle())
        }
        #else
        content.background(CassiniTheme.chipFill, in: Circle())
        #endif
    }
}

struct FloatingSidebarGlassModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(NativeSidebarMaterial())
                .clipShape(shape)
                .overlay {
                    shape.stroke(CassiniTheme.cardStroke, lineWidth: 1)
                }
        }
        #else
        content
            .background(NativeSidebarMaterial())
            .clipShape(shape)
            .overlay {
                shape.stroke(CassiniTheme.cardStroke, lineWidth: 1)
            }
        #endif
    }
}

struct SidebarBottomScrollEdgeModifier: ViewModifier {
    let hasContentBelow: Bool

    private var bottomFadeMask: some View {
        GeometryReader { proxy in
            let height = max(1, proxy.size.height)
            let footerInset = max(36, proxy.safeAreaInsets.bottom)
            let footerTop = max(0, height - footerInset)
            if hasContentBelow && footerTop > 24 {
                let fadeStart = max(0, footerTop - 52)
                let fadeMid = max(fadeStart, footerTop - 24)
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: fadeStart / height),
                        .init(color: .black.opacity(0.28), location: fadeMid / height),
                        .init(color: .clear, location: footerTop / height),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                Rectangle()
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .mask { bottomFadeMask }
        } else {
            content
                .mask { bottomFadeMask }
        }
        #else
        content
            .mask { bottomFadeMask }
        #endif
    }
}

struct SidebarDropFooterModifier<Footer: View>: ViewModifier {
    let footer: () -> Footer

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.safeAreaBar(edge: .bottom, spacing: 0) {
                footer()
            }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                footer()
                    .background(
                        LinearGradient(
                            colors: [CassiniTheme.sidebarMacReference.opacity(0), CassiniTheme.sidebarMacReference],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
        #else
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            footer()
                .background(
                    LinearGradient(
                        colors: [CassiniTheme.sidebarMacReference.opacity(0), CassiniTheme.sidebarMacReference],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        #endif
    }
}

struct UpdateReadyFooter: View {
    let updates: ApplicationUpdates
    var body: some View {
        if updates.readyWhenIdle {
            Text(UXText.text("updates.readyWhenIdle")).font(.system(size: 11.5)).foregroundStyle(CassiniTheme.ink2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 8)
                .accessibilityIdentifier("library-update-ready")
        }
    }
}

struct ConditionalNativeSidebarSearch: ViewModifier {
    let enabled: Bool
    @Binding var query: String
    @Binding var isPresented: Bool
    let prompt: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(
                text: $query,
                isPresented: $isPresented,
                placement: .sidebar,
                prompt: prompt
            )
        } else {
            content
        }
    }
}
