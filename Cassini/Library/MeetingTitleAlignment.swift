// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// Native toolbar margins vary across macOS versions. Keep the title aligned
/// with the meeting pane using its actual window coordinates, not an OS guess.
struct MeetingTitleAlignment: NSViewRepresentable {
    static let targetWindowMinX: CGFloat = 280

    @Binding var inset: CGFloat
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.inset = inset
        view.updateInset = { previous, proposed in
            guard inset == previous else { return }
            inset = proposed
        }
        view.scheduleMeasurement()
    }

    static func proposedInset(current: CGFloat, windowMinX: CGFloat) -> CGFloat? {
        // The existing Meeting board contract starts the title at 280:
        // the 260-point speaker pane followed by 20 points of spacing.
        let raw = current + targetWindowMinX - windowMinX
        guard current.isFinite, windowMinX.isFinite, raw.isFinite else { return nil }
        let clamped = min(targetWindowMinX, max(0, raw))
        guard abs(clamped - current) > 0.5 else { return nil }
        return clamped
    }

    final class Probe: NSView {
        var inset: CGFloat = 44
        var updateInset: ((CGFloat, CGFloat) -> Void)?
        #if DEBUG
        var isScheduled: Bool { scheduled }
        #endif
        private var scheduled = false
        private var ancestorTokens: [NSObjectProtocol] = []

        deinit { clearAncestorObservers() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            rebuildAncestorObservers()
            scheduleMeasurement()
        }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            rebuildAncestorObservers()
            scheduleMeasurement()
        }
        override func layout() { super.layout(); scheduleMeasurement() }
        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin); scheduleMeasurement()
        }

        private func clearAncestorObservers() {
            ancestorTokens.forEach(NotificationCenter.default.removeObserver)
            ancestorTokens.removeAll()
        }

        private func rebuildAncestorObservers() {
            clearAncestorObservers()
            guard window != nil else { return }
            var current = superview
            while let ancestor = current {
                ancestor.postsFrameChangedNotifications = true
                ancestorTokens.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: ancestor,
                    queue: nil
                ) { [weak self] _ in
                    if Thread.isMainThread {
                        MainActor.assumeIsolated { self?.scheduleMeasurement() }
                    } else {
                        Task { @MainActor [weak self] in self?.scheduleMeasurement() }
                    }
                })
                current = ancestor.superview
            }
        }

        func scheduleMeasurement() {
            guard !scheduled else { return }
            scheduled = true
            Task { @MainActor [weak self] in
                self?.measure()
            }
        }

        @MainActor func measure() {
            guard let window, bounds.width > 0 else {
                scheduled = false
                return
            }
            window.layoutIfNeeded()
            scheduled = false
            guard self.window != nil, bounds.width > 0 else { return }
            let current = inset
            if let proposed = MeetingTitleAlignment.proposedInset(
                current: current,
                windowMinX: convert(bounds.origin, to: nil).x
            ) {
                updateInset?(current, proposed)
            }
        }
    }

    #if DEBUG
    @MainActor static func nativeSelfTest() -> [String: Bool] {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 100))
        window.contentView = root
        let toolbarItem = NSView(frame: NSRect(x: 236, y: 10, width: 300, height: 40))
        let paddedHost = NSView(frame: NSRect(x: 44, y: 0, width: 200, height: 24))
        let probe = Probe(frame: paddedHost.bounds)

        var stateInset: CGFloat = 44
        var updates: [CGFloat] = []
        probe.inset = stateInset
        probe.updateInset = { previous, proposed in
            guard stateInset == previous else { return }
            stateInset = proposed
            updates.append(proposed)
            probe.inset = stateInset
            paddedHost.setFrameOrigin(NSPoint(x: stateInset, y: 0))
        }

        paddedHost.addSubview(probe)
        toolbarItem.addSubview(paddedHost)
        root.addSubview(toolbarItem)
        probe.measure()

        var report: [String: Bool] = [:]
        report["titleAlignmentMacOS15KeepsInset44"] =
            updates.isEmpty && stateInset == 44 && abs(probe.convert(probe.bounds.origin, to: nil).x - 280) < 0.5

        toolbarItem.setFrameOrigin(NSPoint(x: 206, y: 10))
        let scheduledOn206 = probe.isScheduled
        probe.measure()
        probe.measure()
        report["titleAlignmentMacOS27AlignsFrom206To280"] =
            scheduledOn206 && updates == [74] && stateInset == 74 && abs(probe.convert(probe.bounds.origin, to: nil).x - 280) < 0.5

        toolbarItem.setFrameOrigin(NSPoint(x: 250, y: 10))
        let scheduledOn250 = probe.isScheduled
        probe.measure()
        report["titleAlignmentAncestorShiftRealigns"] =
            scheduledOn250 && updates == [74, 30] && stateInset == 30 && abs(probe.convert(probe.bounds.origin, to: nil).x - 280) < 0.5

        toolbarItem.setFrameOrigin(NSPoint(x: 295, y: 10))
        let scheduledOn295 = probe.isScheduled
        probe.measure()
        probe.measure()
        report["titleAlignmentWideLeadingControlsClampToZero"] =
            scheduledOn295 && updates == [74, 30, 0] && stateInset == 0 && abs(probe.convert(probe.bounds.origin, to: nil).x - 295) < 0.5

        let passThrough = probe.hitTest(NSPoint(x: 5, y: 5)) == nil
        probe.removeFromSuperview()
        probe.measure()
        toolbarItem.setFrameOrigin(NSPoint(x: 210, y: 10))
        report["titleAlignmentPassThroughHitTesting"] = passThrough && !probe.isScheduled

        probe.updateInset?(999, 12)
        report["titleAlignmentRejectsStaleAndInvalidProposals"] =
            updates == [74, 30, 0] &&
            stateInset == 0 &&
            proposedInset(current: 44, windowMinX: .nan) == nil &&
            proposedInset(current: 44, windowMinX: .infinity) == nil &&
            proposedInset(current: 44, windowMinX: -20) == 280 &&
            proposedInset(current: 44, windowMinX: 280.25) == nil

        return report
    }
    #endif
}
