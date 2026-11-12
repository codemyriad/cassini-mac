// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// W2.3 surface only. The host owns selection, keyboard navigation and content.
/// Keep this outside the app target until agy-mac wires the Library list.
struct MeetingCard<Content: View>: View {
    let isSelected: Bool
    private let content: Content
    @Environment(\.colorScheme) private var scheme

    init(isSelected: Bool, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.content = content()
    }

    enum Metrics {
        static var radius: CGFloat { 7 }
        static var horizontalPadding: CGFloat { 10 }
        static var verticalPadding: CGFloat { 8 }
        static var border: CGFloat { 1 }
        static var selectedInset: CGFloat { 0.5 }
        static var interCardGap: CGFloat { 6 }
        static var shadowRadius: CGFloat { 4 }
        static var shadowY: CGFloat { 2 }
    }

    var body: some View {
        let dark = scheme == .dark
        let paint = MeetingCardPaint(dark: dark, selected: isSelected)
        let shape = RoundedRectangle(cornerRadius: Metrics.radius)
        content
            .foregroundStyle(Color(nsColor: paint.ink))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.vertical, Metrics.verticalPadding)
            .padding(Metrics.border)
            .background {
                shape.fill(Color(nsColor: paint.fill))
                    .shadow(color: Color(nsColor: paint.shadow), radius: Metrics.shadowRadius, y: Metrics.shadowY)
            }
            .overlay {
                shape.strokeBorder(Color(nsColor: paint.border),
                    lineWidth: Metrics.border + (isSelected ? Metrics.selectedInset : 0))
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// All colours originate in the generated token sheet. Mixtures use sRGB
/// components, as Row-Mac's color-mix(in srgb, ...) specifies.
struct MeetingCardPaint {
    let fill: NSColor
    let border: NSColor
    let ink: NSColor
    let shadow: NSColor

    init(dark: Bool, selected: Bool) {
        ink = CassiniTokens.inkEntry.resolvedNSColor(dark: dark)
        let surface = CassiniTokens.surfaceEntry.resolvedNSColor(dark: dark)
        fill = selected ? (dark ? Self.mix(ink, fraction: 0.06, into: surface) : surface)
            : CassiniTokens.cardRestEntry.resolvedNSColor(dark: dark)
        border = selected ? Self.mix(ink, fraction: dark ? 0.5 : 0.55, into: surface)
            : CassiniTokens.lineEntry.resolvedNSColor(dark: dark)
        shadow = CassiniTokens.inkEntry.resolvedNSColor(dark: false)
            .withAlphaComponent(selected && !dark ? 0.12 : 0)
    }

    private static func mix(_ first: NSColor, fraction: CGFloat, into second: NSColor) -> NSColor {
        NSColor(srgbRed: first.redComponent * fraction + second.redComponent * (1-fraction),
                green: first.greenComponent * fraction + second.greenComponent * (1-fraction),
                blue: first.blueComponent * fraction + second.blueComponent * (1-fraction), alpha: 1)
    }
}
