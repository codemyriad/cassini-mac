// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniLibrary
import CassiniSpectrogram
import SwiftUI

/// Semantic colour roles for the macOS app, backed by `CassiniTokens` (`brand/tokens.json` Wave 1).
enum CassiniTheme {
    /// All decided roles from `brand/tokens.json` are applied in W1 look preview.
    static let unappliedDecidedTokens: Set<String> = []

    private static func adaptiveNS(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    // Scene tint (L-06, L-18)
    static let sceneTint: Color? = CassiniTokens.accent

    // Grounds & surfaces (L-16, L-17, L-18, L-19, C18)
    static let paneGround = CassiniTokens.ground
    static let nsPaneGround: NSColor = CassiniTokens.ns.ground
    static let windowGround = CassiniTokens.ground
    static let sidebarGround = CassiniTokens.sunken
    static let surface = CassiniTokens.surface
    static let raised = CassiniTokens.raised
    static let cardRest = CassiniTokens.cardRest
    static let nsChipFill: NSColor = CassiniTokens.ns.neutralTint
    static let chipFill = CassiniTokens.neutralTint
    static let controlFill = CassiniTokens.surface
    static let subtleWash = CassiniTokens.sunken
    static let ratePillFill = CassiniTokens.neutralTint

    // Lines & borders (L-16, L-18)
    static let cardStroke = CassiniTokens.line
    static let modelCardStroke = CassiniTokens.line
    static let tagStroke = CassiniTokens.line
    static let secondaryTagStroke = CassiniTokens.line
    static let lineSoft = CassiniTokens.lineSoft
    static let nsSeparator: NSColor = CassiniTokens.ns.line

    // Inks & placeholders (L-16, L-18, L-36; HARMONY 10.8)
    static let ink = CassiniTokens.ink
    static let nsInk: NSColor = CassiniTokens.ns.ink
    static let primaryInk = CassiniTokens.ink
    static let ink2 = CassiniTokens.ink2
    static let secondaryInk = CassiniTokens.ink2
    static let secondaryColor = CassiniTokens.ink2
    static let ink3 = CassiniTokens.ink3
    static let nsInk2: NSColor = CassiniTokens.ns.ink2
    static let nsInk3: NSColor = CassiniTokens.ns.ink3
    static let nsUpcomingWordInk: NSColor = CassiniTokens.ns.ink3
    static func nsInactiveChipFill(dark: Bool) -> NSColor {
        CassiniTokens.neutralTintEntry.resolvedNSColor(dark: dark)
    }

    // Accents (L-06, L-17, L-18)
    static let accent = CassiniTokens.accent
    static let nsAccent: NSColor = CassiniTokens.ns.accent
    static let accentStrong = CassiniTokens.accentStrong
    static let onAccent = CassiniTokens.onAccent
    static let onAccentDim = CassiniTokens.onAccent.opacity(0.82)
    static let accentInk = CassiniTokens.accentInk
    static let accentTint = CassiniTokens.accentTint
    static let activeModelWash = CassiniTokens.accentTint
    static let listeningRowWash = CassiniTokens.accent.opacity(0.08)
    static let selectedOptionWash = CassiniTokens.accentTint

    // Highlights (L-24)
    static let nsHighlight: NSColor = CassiniTokens.ns.highlight
    static let nsSearchHighlight: NSColor = CassiniTokens.ns.highlight
    static let nsHighlightInk: NSColor? = CassiniTokens.ns.highlightInk
    static let nsSelectedSearchHighlight = adaptiveNS(
        light: CassiniTokens.onAccentEntry.resolvedNSColor(dark: false).withAlphaComponent(0.28),
        dark: CassiniTokens.onAccentEntry.resolvedNSColor(dark: true).withAlphaComponent(0.14)
    )
    static func nsLegacyMatchFill(dark: Bool, isCurrent: Bool) -> NSColor {
        CassiniTokens.highlightEntry.resolvedNSColor(dark: dark).withAlphaComponent(isCurrent ? 1.0 : 0.65)
    }

    // Record & spectrogram roles (L-07, L-20; HARMONY 10.2, 10.3)
    static let nsRecord: NSColor = CassiniTokens.ns.record
    static let record = CassiniTokens.record
    static let nsRecordInk: NSColor = CassiniTokens.ns.recordInk
    static let recordInk = CassiniTokens.recordInk
    static let recordTint = CassiniTokens.recordTint
    static let onRecord = CassiniTokens.onRecord
    static let nsOnRecord: NSColor = CassiniTokens.ns.onRecord
    static func nsLivePillInk(dark: Bool) -> NSColor {
        CassiniTokens.recordInkEntry.resolvedNSColor(dark: dark)
    }
    static func nsLivePillStopFill(dark: Bool) -> NSColor {
        CassiniTokens.recordEntry.resolvedNSColor(dark: dark)
    }
    static func nsLivePillWash(dark: Bool) -> NSColor {
        CassiniTokens.recordTintEntry.resolvedNSColor(dark: dark)
    }
    static let spectrogramColors = SpectrogramThemeColors(
        pillInkLight: CassiniTokens.recordInkEntry.lightRGB,
        pillInkDark: CassiniTokens.recordInkEntry.darkRGB,
        rowInkLight: CassiniTokens.inkEntry.lightRGB,
        rowInkDark: CassiniTokens.inkEntry.darkRGB,
        pillSilentLight: CassiniTokens.warnInkEntry.lightRGB,
        pillSilentDark: CassiniTokens.warnInkEntry.darkRGB,
        rowSilentLight: CassiniTokens.warnInkEntry.lightRGB,
        rowSilentDark: CassiniTokens.warnInkEntry.darkRGB
    )

    // Status, destructive/success fills & inverse roles (L-16, L-26, L-37, L-38; HARMONY 10.4–10.7)
    static let warnInk = CassiniTokens.warnInk
    static let warnTint = CassiniTokens.warnTint
    static let inlineWarnInk = CassiniTokens.warnInk
    static let inlineWarnTint = CassiniTokens.warnTint
    static let warningNotice = CassiniTokens.warnInk
    static let neutralInk = CassiniTokens.neutralInk
    static let neutralTint = CassiniTokens.neutralTint
    static func badgeInk(_ tint: String) -> Color {
        switch tint {
        case "red": return recordInk
        case "amber": return warnInk
        case "accent": return neutralInk
        default: return neutralInk
        }
    }
    static func badgeWash(_ tint: String) -> Color {
        switch tint {
        case "red": return recordTint
        case "amber": return warnTint
        case "accent": return neutralTint
        default: return neutralTint
        }
    }
    static let success = CassiniTokens.success
    static let successTint = CassiniTokens.successTint
    static let successFill = CassiniTokens.successFill
    static let stepDoneFill = CassiniTokens.successFill
    static let onSuccess = CassiniTokens.onRecord
    static let error = CassiniTokens.error
    static let errorTint = CassiniTokens.errorTint
    static let errorFill = CassiniTokens.errorFill
    static let nsErrorFill: NSColor = CassiniTokens.ns.errorFill
    static let onErrorFill = CassiniTokens.onRecord
    static let inverse = CassiniTokens.inverse
    static let onInverse = CassiniTokens.onInverse
    static let inverseAccent = CassiniTokens.inverseAccent
    static let scrim = CassiniTokens.scrim
    static let shadow = CassiniTokens.shadow
    static let toastUsesInverse = true

    // Speaker & avatar roles (L-14; HARMONY 10.10–10.12; provisional colourIndex mapping pending Alex)
    static func speakerSlot(colourIndex: Int, unnamed: Bool) -> Int {
        guard !unnamed else { return 0 }
        return ((colourIndex % 6) + 6) % 6 + 1
    }

    static func speakerSlot(_ speaker: MeetingSpeaker?) -> Int {
        guard let speaker else { return 0 }
        let unnamed = speaker.provenance == .unnamed
            || (speaker.provenance == nil && speaker.name == nil && speaker.label == nil)
        return speakerSlot(colourIndex: speaker.colourIndex, unnamed: unnamed)
    }

    private static let speakerInks: [Color] = [
        CassiniTokens.speaker0,
        CassiniTokens.speaker1,
        CassiniTokens.speaker2,
        CassiniTokens.speaker3,
        CassiniTokens.speaker4,
        CassiniTokens.speaker5,
        CassiniTokens.speaker6,
    ]

    private static let nsSpeakerInks: [NSColor] = [
        CassiniTokens.ns.speaker0,
        CassiniTokens.ns.speaker1,
        CassiniTokens.ns.speaker2,
        CassiniTokens.ns.speaker3,
        CassiniTokens.ns.speaker4,
        CassiniTokens.ns.speaker5,
        CassiniTokens.ns.speaker6,
    ]

    private static let speakerWashes: [Color] = [
        CassiniTokens.avatar0,
        CassiniTokens.avatar1,
        CassiniTokens.avatar2,
        CassiniTokens.avatar3,
        CassiniTokens.avatar4,
        CassiniTokens.avatar5,
        CassiniTokens.avatar6,
    ]

    private static let nsSpeakerWashes: [NSColor] = [
        CassiniTokens.ns.avatar0,
        CassiniTokens.ns.avatar1,
        CassiniTokens.ns.avatar2,
        CassiniTokens.ns.avatar3,
        CassiniTokens.ns.avatar4,
        CassiniTokens.ns.avatar5,
        CassiniTokens.ns.avatar6,
    ]

    static func speakerInk(_ speaker: MeetingSpeaker?) -> Color {
        speakerInks[speakerSlot(speaker)]
    }

    static func nsSpeakerInk(_ speaker: MeetingSpeaker?) -> NSColor {
        nsSpeakerInks[speakerSlot(speaker)]
    }

    static func speakerWash(_ speaker: MeetingSpeaker?) -> Color {
        speakerWashes[speakerSlot(speaker)]
    }

    static func nsSpeakerWash(_ speaker: MeetingSpeaker?) -> NSColor {
        nsSpeakerWashes[speakerSlot(speaker)]
    }

    static func speakerInk(colourIndex: Int, unnamed: Bool = false) -> Color {
        speakerInks[speakerSlot(colourIndex: colourIndex, unnamed: unnamed)]
    }

    static func nsSpeakerInk(colourIndex: Int, unnamed: Bool = false) -> NSColor {
        nsSpeakerInks[speakerSlot(colourIndex: colourIndex, unnamed: unnamed)]
    }
}
