// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Neutral meeting card surface for desktop Library and Search lists (L-19, L-42, L-54).
/// The host owns selection, keyboard navigation, context menus, and content.
struct MeetingCard<Content: View>: View {
    let isSelected: Bool
    private let content: Content
    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

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
                    .overlay {
                        if isHovered && !isSelected {
                            shape.fill(Color(nsColor: paint.ink).opacity(0.04))
                        }
                    }
                    .shadow(color: Color(nsColor: paint.shadow), radius: Metrics.shadowRadius, y: Metrics.shadowY)
            }
            .overlay {
                shape.strokeBorder(Color(nsColor: paint.border),
                    lineWidth: Metrics.border + (isSelected ? Metrics.selectedInset : 0))
            }
            .onHover { isHovered = $0 }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// All colours originate in the generated token sheet. Mixtures use sRGB
/// components, matching Row-Mac.dc.html's color-mix(in srgb, ...) spec (L-19, L-42, L-54).
struct MeetingCardPaint {
    let fill: NSColor
    let border: NSColor
    let ink: NSColor
    let shadow: NSColor

    init(dark: Bool, selected: Bool) {
        ink = CassiniTokens.inkEntry.resolvedNSColor(dark: dark)
        let surface = CassiniTokens.surfaceEntry.resolvedNSColor(dark: dark)
        let raised = CassiniTokens.raisedEntry.resolvedNSColor(dark: dark)
        if selected {
            fill = dark ? Self.mix(ink, fraction: 0.07, into: raised) : surface
            border = Self.mix(ink, fraction: dark ? 0.50 : 0.55, into: surface)
        } else {
            fill = CassiniTokens.cardRestEntry.resolvedNSColor(dark: dark)
            border = CassiniTokens.lineEntry.resolvedNSColor(dark: dark)
        }
        shadow = CassiniTokens.inkEntry.resolvedNSColor(dark: false)
            .withAlphaComponent(selected && !dark ? 0.12 : 0)
    }

    #if DEBUG
    /// Pins the resting fill to card-rest in both modes (L-19, HARMONY §10.9) and checks
    /// that the selected fill stays lighter than the resting fill in dark mode.
    static func nativeSelfTest() -> [String: Bool] {
        func hex(_ color: NSColor) -> String? {
            guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
            return String(format: "#%02X%02X%02X", Int((srgb.redComponent * 255).rounded()),
                          Int((srgb.greenComponent * 255).rounded()), Int((srgb.blueComponent * 255).rounded()))
        }
        func luma(_ color: NSColor) -> CGFloat {
            guard let c = color.usingColorSpace(.sRGB) else { return 0 }
            return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }
        let restLight = MeetingCardPaint(dark: false, selected: false).fill
        let restDark = MeetingCardPaint(dark: true, selected: false).fill
        let selectedDark = MeetingCardPaint(dark: true, selected: true).fill
        return [
            "meetingCardRestLightIsCardRest": hex(restLight) == CassiniTokens.cardRestEntry.light.uppercased()
                && hex(restLight) == "#FAFAFB",
            "meetingCardRestDarkIsCardRest": hex(restDark) == CassiniTokens.cardRestEntry.dark.uppercased()
                && hex(restDark) == "#171A20",
            "meetingCardSelectedDarkLiftsAboveRest": luma(selectedDark) > luma(restDark) + 0.03,
        ]
    }
    #endif

    private static func mix(_ first: NSColor, fraction: CGFloat, into second: NSColor) -> NSColor {
        NSColor(srgbRed: first.redComponent * fraction + second.redComponent * (1 - fraction),
                green: first.greenComponent * fraction + second.greenComponent * (1 - fraction),
                blue: first.blueComponent * fraction + second.blueComponent * (1 - fraction), alpha: 1)
    }
}
