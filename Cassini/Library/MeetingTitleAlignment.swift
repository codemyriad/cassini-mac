// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Native toolbar margins vary across macOS versions. Keep the title aligned
/// with the meeting pane using its actual window coordinates, not an OS guess.
struct MeetingTitleAlignment: NSViewRepresentable {
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
    final class Probe: NSView {
        var inset: CGFloat = 44
        var updateInset: ((CGFloat, CGFloat) -> Void)?
        private var scheduled = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); scheduleMeasurement()
        }
        override func layout() { super.layout(); scheduleMeasurement() }
        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin); scheduleMeasurement()
        }
        func scheduleMeasurement() {
            guard !scheduled else { return }
            scheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                scheduled = false
                guard window != nil, bounds.width > 0 else { return }
                // The existing Meeting board contract starts the title at280:
                // the260-point speaker pane followed by20 points of spacing.
                let proposed = inset + 280 - convert(bounds.origin, to:nil).x
                guard proposed.isFinite, proposed >= 0, proposed <= 280,
                      abs(proposed - inset) > 0.5 else { return }
                updateInset?(inset, proposed)
            }
        }
    }
}
