// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniLibrary
import SwiftUI

enum LibraryDropState: Equatable {
    case idle
    case enteredWindow
    case supportedOverList
    case unsupportedOverList(fileName: String)

    var dimsListContent: Bool {
        switch self {
        case .supportedOverList, .unsupportedOverList:
            return true
        case .idle, .enteredWindow:
            return false
        }
    }

    var showsWindowOutline: Bool {
        self == .enteredWindow
    }

    static func formattedUnsupportedFileNames(_ urls: [URL], locale: Locale = UXText.locale) -> String {
        let names = urls.map(\.lastPathComponent).filter { !$0.isEmpty }
        guard let first = names.first else { return "" }
        if names.count == 1 { return first }
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: names) ?? first
    }
}

/// Incoming-tray glyph from `Library-Mac.dc.html` / `DropImport.dc.html` (`M12 4v10 M8 10l4 4 4-4 M4 16v3.5h16V16`).
struct ImportTrayIcon: View {
    var size: CGFloat = 16
    var strokeWidth: CGFloat = 2

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height) / 24.0
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scale, y: y * scale)
            }
            var path = Path()
            path.move(to: pt(12, 4))
            path.addLine(to: pt(12, 14))
            path.move(to: pt(8, 10))
            path.addLine(to: pt(12, 14))
            path.addLine(to: pt(16, 10))
            path.move(to: pt(4, 16))
            path.addLine(to: pt(4, 19.5))
            path.addLine(to: pt(20, 19.5))
            path.addLine(to: pt(20, 16))
            context.stroke(
                path,
                with: .foreground,
                style: StrokeStyle(lineWidth: strokeWidth * (size / 16.0 > 1.2 ? 1.15 : 1.0), lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Circle-exclamation alert glyph from `DropImport.dc.html` state 4 (`circle cx=12 cy=12 r=9`, `M12 7.5v5.5`, `M12 16.5v.01`).
private struct ImportErrorAlertIcon: View {
    var size: CGFloat = 28

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height) / 24.0
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scale, y: y * scale)
            }
            let r = 9.0 * scale
            let circle = Path(ellipseIn: CGRect(x: 12 * scale - r, y: 12 * scale - r, width: r * 2, height: r * 2))
            var stem = Path()
            stem.move(to: pt(12, 7.5))
            stem.addLine(to: pt(12, 13.0))
            context.stroke(circle, with: .foreground, style: StrokeStyle(lineWidth: 2.1, lineCap: .round))
            context.stroke(stem, with: .foreground, style: StrokeStyle(lineWidth: 2.1, lineCap: .round))
            let dotR: CGFloat = 1.25
            let dot = Path(ellipseIn: CGRect(x: 12 * scale - dotR, y: 16.5 * scale - dotR, width: dotR * 2, height: dotR * 2))
            context.fill(dot, with: .foreground)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Sidebar header `Import Audio…` icon button (`L-25`, `Library-Mac.dc.html` line 23).
struct LibraryImportHeaderButton: View {
    let enabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let label = UXText.text("import.action")
        Button(action: action) {
            ImportTrayIcon(size: 16, strokeWidth: 2)
                .foregroundStyle(enabled ? CassiniTheme.ink2 : CassiniTheme.ink3)
                .frame(width: 34, height: 34)
                .background(isHovered && enabled ? CassiniTheme.ink.opacity(0.08) : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("toolbar-import")
    }
}

/// Pinned resting / window-enter hint footer at the foot of the Library sidebar (`L-25`, `DropImport.dc.html` states 1–2).
struct LibraryDropHintFooter: View {
    let entered: Bool

    var body: some View {
        HStack(spacing: 6) {
            ImportTrayIcon(size: 14, strokeWidth: 2)
            Text(UXText.text(entered ? "import.drop.enter" : "import.drop.rest"))
                .lineLimit(1)
        }
        .font(.system(size: 11.5, weight: entered ? .semibold : .regular))
        .foregroundStyle(entered ? CassiniTheme.accentInk : CassiniTheme.ink3)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(CassiniTheme.lineSoft).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library-drop-hint")
    }
}

/// Drop-target overlay over the meeting list (`L-25`, `DropImport.dc.html` states 2–4).
struct LibraryDropListOverlay: View {
    let state: LibraryDropState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .enteredWindow:
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(CassiniTheme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .padding(8)
                .allowsHitTesting(false)
        case .supportedOverList:
            let shape = RoundedRectangle(cornerRadius: 10)
            VStack(spacing: 8) {
                ImportTrayIcon(size: 28, strokeWidth: 2)
                    .foregroundStyle(CassiniTheme.accent)
                Text(UXText.text("import.drop.over"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(CassiniTheme.ink)
                    .multilineTextAlignment(.center)
                Text(UXText.mac("import.drop.formats"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(CassiniTheme.ink2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(CassiniTheme.highlight.opacity(0.88)))
            .overlay(shape.strokeBorder(CassiniTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
            .padding(10)
            .allowsHitTesting(false)
            .accessibilityIdentifier("library-drop-overlay-supported")
        case .unsupportedOverList(let fileName):
            let shape = RoundedRectangle(cornerRadius: 10)
            let formats = UXText.mac("import.drop.formats")
            VStack(spacing: 8) {
                ImportErrorAlertIcon(size: 28)
                    .foregroundStyle(CassiniTheme.error)
                Text(UXText.text("import.drop.cantImport", ["file": fileName]))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(CassiniTheme.error)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Text(UXText.text("import.drop.cantImport.detail", ["formats": formats]))
                    .font(.system(size: 11.5))
                    .foregroundStyle(CassiniTheme.ink2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(CassiniTheme.errorTint.opacity(0.88)))
            .overlay(shape.strokeBorder(CassiniTheme.error, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
            .padding(10)
            .allowsHitTesting(false)
            .accessibilityIdentifier("library-drop-overlay-unsupported")
        }
    }
}

/// Passive full-window `NSDraggingDestination` (`hitTest` returns `nil` so clicks,
/// scrolls, double-clicks, context menus, and VoiceOver hit-testing pass straight through).
struct LibraryWindowDropDestination: NSViewRepresentable {
    @Binding var state: LibraryDropState
    /// Width of the left sidebar drop target when in split view (`nil` when the entire view is the target).
    let sidebarDropWidth: CGFloat?
    let showsVisualStates: Bool
    let onDropFiles: ([URL]) -> Void

    final class View: NSView {
        var sidebarDropWidth: CGFloat?
        var showsVisualStates = true
        var onStateChange: ((LibraryDropState) -> Void)?
        var onDropFiles: (([URL]) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.fileURL])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Programmatic view") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func draggedFiles(from sender: NSDraggingInfo) -> [URL] {
            let objects = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
            return objects.filter { $0.isFileURL && !$0.hasDirectoryPath }
        }

        /// Off-main header probe cached per drag session; hover handlers only read it.
        private lazy var probeSession: ImportDropProbeSession = {
            let session = ImportDropProbeSession(
                probe: ImportDropProbeSession.blockingProbe { LibraryImportCoordinator.isSupportedDropURL($0) }
            )
            session.onResolved = { [weak self] in self?.probeDidResolve() }
            return session
        }()
        /// Last hover snapshot, so a late probe result can refresh the overlay without new drag events.
        private var lastHover: (files: [URL], point: NSPoint)?

        /// Supported files from in-memory state only: the cached probe result when the session's
        /// probe has finished, otherwise extension-only classification (the importer revalidates
        /// content off-main, so an early drop of a disguised file lands in `Needs attention`).
        private func supportedFiles(in files: [URL]) -> [URL] {
            let candidates = files.filter(LibraryImportCoordinator.isSupportedDropExtension)
            guard !candidates.isEmpty else {
                probeSession.reset()
                return []
            }
            switch probeSession.resolution(for: candidates) {
            case .pending:
                return candidates
            case .resolved(let supported):
                return supported
            }
        }

        private func isOverTarget(_ point: NSPoint) -> Bool {
            if let width = sidebarDropWidth {
                return point.x >= 0 && point.x <= width && bounds.contains(point)
            }
            return bounds.contains(point)
        }

        private func evaluate(_ sender: NSDraggingInfo) -> NSDragOperation {
            let files = draggedFiles(from: sender)
            let point = convert(sender.draggingLocation, from: nil)
            lastHover = files.isEmpty ? nil : (files: files, point: point)
            return evaluate(files: files, point: point)
        }

        private func evaluate(files: [URL], point: NSPoint) -> NSDragOperation {
            guard !files.isEmpty else {
                probeSession.reset()
                onStateChange?(.idle)
                return []
            }
            let supported = supportedFiles(in: files)
            guard showsVisualStates else {
                onStateChange?(.idle)
                return !supported.isEmpty || files.count > 1 ? .copy : []
            }
            if !isOverTarget(point) {
                onStateChange?(.enteredWindow)
                return []
            }
            if supported.isEmpty {
                onStateChange?(.unsupportedOverList(fileName: LibraryDropState.formattedUnsupportedFileNames(files)))
                return []
            }
            onStateChange?(.supportedOverList)
            return .copy
        }

        /// Main-actor delivery of the current session's probe result. The returned
        /// `NSDragOperation` follows on AppKit's next periodic `draggingUpdated`.
        private func probeDidResolve() {
            guard let lastHover else { return }
            _ = evaluate(files: lastHover.files, point: lastHover.point)
        }

        private func endDragSession() {
            probeSession.reset()
            lastHover = nil
            onStateChange?(.idle)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            MainActor.assumeIsolated { evaluate(sender) }
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            MainActor.assumeIsolated { evaluate(sender) }
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            MainActor.assumeIsolated { endDragSession() }
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            MainActor.assumeIsolated { endDragSession() }
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            MainActor.assumeIsolated { endDragSession() }
        }

        /// Decides from in-memory state only, so it is deterministic even when the hover
        /// probe has not finished (or is stalled on a network mount).
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            MainActor.assumeIsolated {
                defer { endDragSession() }
                let files = draggedFiles(from: sender)
                guard !files.isEmpty else { return false }
                let supported = supportedFiles(in: files)
                if showsVisualStates, sidebarDropWidth != nil {
                    guard isOverTarget(convert(sender.draggingLocation, from: nil)) else { return false }
                }
                guard !supported.isEmpty || (!showsVisualStates && files.count > 1) else { return false }
                onDropFiles?(files)
                return true
            }
        }
    }

    func makeNSView(context: Context) -> View {
        let view = View()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: View, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: View) {
        view.sidebarDropWidth = sidebarDropWidth
        view.showsVisualStates = showsVisualStates
        view.onStateChange = { next in
            if state != next { state = next }
        }
        view.onDropFiles = onDropFiles
    }
}
