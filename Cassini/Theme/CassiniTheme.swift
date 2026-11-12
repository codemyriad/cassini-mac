// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniSpectrogram
import SwiftUI

/// Semantic colour roles for the macOS app.
/// W1.1 plumbing: every role is routed through this single theme enum while returning
/// today's pre-W1 colours so zero pixels change. PR B switches roles to `CassiniTokens`
/// and empties `unappliedDecidedTokens`.
enum CassiniTheme {
    /// Decided roles from `brand/tokens.json` not yet applied to visible surfaces in PR A.
    /// PR B (`W1 look preview`) applies every decided role and leaves this set empty.
    static let unappliedDecidedTokens: Set<String> = [
        "ground", "surface", "sunken", "raised", "line", "line-soft",
        "ink", "ink-2", "ink-3",
        "accent", "accent-strong", "on-accent", "accent-ink", "accent-tint",
        "record", "record-ink", "record-tint", "on-record",
        "error-fill", "success-fill",
        "error", "error-tint", "success", "success-tint",
        "warn-ink", "warn-tint", "neutral-ink", "neutral-tint",
        "highlight", "highlight-ink",
        "speaker-1", "speaker-2", "speaker-3", "speaker-4", "speaker-5", "speaker-6", "speaker-0",
        "avatar-1", "avatar-2", "avatar-3", "avatar-4", "avatar-5", "avatar-6", "avatar-0",
        "inverse", "on-inverse", "inverse-accent", "scrim", "shadow",
        "card-rest",
    ]

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: adaptiveNS(light: light, dark: dark))
    }

    private static func adaptiveNS(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    // Scene tint (W1: CassiniTokens.accent)
    static let sceneTint: Color? = nil

    // Grounds & surfaces (W1: ground, surface, sunken, raised, cardRest)
    static let paneGround = Color(nsColor: .textBackgroundColor)
    static let nsPaneGround: NSColor = .textBackgroundColor
    static let windowGround = Color(nsColor: .windowBackgroundColor)
    static let sidebarGround = adaptive(
        light: NSColor(red: 241/255, green: 240/255, blue: 245/255, alpha: 1),
        dark: .windowBackgroundColor
    )
    static let surface = Color(nsColor: .textBackgroundColor)
    static let nsChipFill = adaptiveNS(
        light: NSColor(red: 239/255, green: 239/255, blue: 243/255, alpha: 1),
        dark: .controlBackgroundColor
    )
    static let chipFill = Color(nsColor: nsChipFill)
    static let controlFill = Color(nsColor: .controlBackgroundColor)
    static let subtleWash = Color.secondary.opacity(0.07)
    static let ratePillFill = Color.secondary.opacity(0.10)

    // Lines & borders (W1: line, lineSoft)
    static let cardStroke = Color.secondary.opacity(0.25)
    static let modelCardStroke = ink2.opacity(0.2)
    static let tagStroke = ink2.opacity(0.3)
    static let secondaryTagStroke = Color.secondary.opacity(0.3)
    static let nsSeparator: NSColor = .separatorColor

    // Inks (W1: ink, ink2, ink3)
    static let ink = Color(nsColor: .labelColor)
    static let nsInk: NSColor = .labelColor
    static let primaryInk = Color.primary
    static let ink2 = adaptive(
        light: NSColor(red: 106/255, green: 106/255, blue: 112/255, alpha: 1),
        dark: .secondaryLabelColor
    )
    static let secondaryInk = HierarchicalShapeStyle.secondary
    static let secondaryColor = Color.secondary
    static let nsInk2: NSColor = .secondaryLabelColor
    static let nsInk3: NSColor = .tertiaryLabelColor
    static let nsUpcomingWordInk: NSColor = .secondaryLabelColor
    static func nsInactiveChipFill(dark: Bool) -> NSColor {
        dark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.035)
    }

    // Accents (W1: accent, accentStrong, onAccent, accentInk, accentTint)
    static let accent = Color.accentColor
    static let nsAccent: NSColor = .controlAccentColor
    static let accentStrong = Color.accentColor
    static let onAccent = Color.white
    static let onAccentDim = Color.white.opacity(0.86)
    static let accentInk = Color.accentColor
    static let accentTint = Color.accentColor.opacity(0.11)
    static let activeModelWash = Color.accentColor.opacity(0.07)
    static let listeningRowWash = Color.accentColor.opacity(0.08)
    static let selectedOptionWash = Color.accentColor.opacity(0.10)

    // Highlights (W1: highlight, highlightInk)
    static let nsHighlight = NSColor(srgbRed: 253/255, green: 230/255, blue: 138/255, alpha: 1)
    static let nsSearchHighlight = NSColor(red: 253/255, green: 230/255, blue: 138/255, alpha: 1)
    static let nsHighlightInk: NSColor? = nil
    static let nsSelectedSearchHighlight = NSColor.white.withAlphaComponent(0.28)
    static func nsLegacyMatchFill(dark: Bool, isCurrent: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: isCurrent ? 0.7 : 0.45)
            : NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: isCurrent ? 0.7 : 0.45)
    }

    // Record & spectrogram roles (W1: record, recordInk, recordTint, onRecord, warnInk, ink)
    static let nsRecord = adaptiveNS(
        light: NSColor(red: 215/255, green: 0, blue: 21/255, alpha: 1),
        dark: .systemRed
    )
    static let record = Color(nsColor: nsRecord)
    static let nsRecordInk = nsRecord
    static let recordInk = record
    static let recordTint = record.opacity(0.10)
    static let onRecord = Color.white
    static let nsOnRecord: NSColor = .white
    static func nsLivePillInk(dark: Bool) -> NSColor {
        dark
            ? NSColor(red: 1, green: 69/255, blue: 58/255, alpha: 1)
            : NSColor(red: 215/255, green: 0, blue: 21/255, alpha: 1)
    }
    static func nsLivePillStopFill(dark: Bool) -> NSColor {
        nsLivePillInk(dark: dark)
    }
    static func nsLivePillWash(dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 67/255, green: 33/255, blue: 31/255, alpha: 1)
            : NSColor(srgbRed: 253/255, green: 228/255, blue: 230/255, alpha: 1)
    }
    static let spectrogramColors = SpectrogramThemeColors(
        pillInkLight: 0xd70015, pillInkDark: 0xff6961,
        rowInkLight: 0x1d1d1f, rowInkDark: 0xf5f5f7,
        pillSilentLight: 0xff9f0a, pillSilentDark: 0xff9f0a,
        rowSilentLight: 0xc47a00, rowSilentDark: 0xff9f0a
    )

    // Status, destructive/success fills & inverse roles
    static let warnInk = adaptive(
        light: NSColor(red: 122/255, green: 77/255, blue: 0, alpha: 1),
        dark: .systemOrange
    )
    static let warnTint = adaptive(
        light: NSColor(red: 1, green: 240/255, blue: 199/255, alpha: 1),
        dark: NSColor.systemOrange.withAlphaComponent(0.16)
    )
    static let inlineWarnInk = Color(red: 122/255, green: 77/255, blue: 0)
    static let inlineWarnTint = Color(red: 1, green: 240/255, blue: 199/255)
    static let warningNotice = Color.orange
    static let neutralInk = ink2
    static let neutralTint = ink2.opacity(0.10)
    static func badgeInk(_ tint: String) -> Color {
        switch tint {
        case "red": return recordInk
        case "amber": return inlineWarnInk
        case "accent": return accent
        default: return neutralInk
        }
    }
    static func badgeWash(_ tint: String) -> Color {
        badgeInk(tint).opacity(0.10)
    }
    static let success = Color.green
    static let successTint = Color.green.opacity(0.12)
    static let successFill = Color(red: 31/255, green: 122/255, blue: 63/255)
    static let stepDoneFill = successFill
    static let onSuccess = Color.white
    static let error = record
    static let errorTint = recordTint
    static let errorFill = record
    static let onErrorFill = Color.white
    static let inverse = Color(nsColor: .labelColor)
    static let onInverse = Color(nsColor: .windowBackgroundColor)
    static let inverseAccent = Color.accentColor
    static let scrim = Color.black.opacity(0.45)
    static let shadow = Color.black.opacity(0.25)
    static let toastUsesInverse = false

    // Speaker & avatar roles (W1: speaker-1..6 + speaker-0, avatar-1..6 + avatar-0)
    static func speakerColour(_ index: Int) -> Color {
        [Color.accentColor, Color(red: 179/255, green: 71/255, blue: 0), Color(red: 125/255, green: 60/255, blue: 152/255)][index % 3]
    }
    static let legacySpeakerPalette: [NSColor] = [.systemOrange, .systemIndigo, .systemTeal, .systemGreen, .systemPink]
}
