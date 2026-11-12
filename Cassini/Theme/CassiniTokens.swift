// SPDX-License-Identifier: GPL-3.0-or-later
// Brand token sheet pinned to codemyriad/cassini-ux brand/tokens.json
// commit e4ae2217312370250a39ad83e047a186048e0a9e (version 2026-11-12.1;
// source: canvas "Cassini talk alignment", project/ui/tokens.css, decisions up to 2026-11-11).
import AppKit
import CryptoKit
import SwiftUI

enum CassiniTokens {
    static let upstreamRepository = "cassini-ux"
    static let upstreamPath = "brand/tokens.json"
    static let upstreamCommit = "e4ae2217312370250a39ad83e047a186048e0a9e"

    struct Entry: Sendable, Equatable {
        let id: String
        let swiftName: String
        let light: String
        let dark: String

        var nsColor: NSColor { CassiniTokens.dynamicSRGB(light: light, dark: dark) }
        var color: Color { Color(nsColor: nsColor) }
        func resolvedNSColor(dark isDark: Bool) -> NSColor { CassiniTokens.parseSRGB(isDark ? dark : light) }
    }

    // Active tokens only (`status` in {"decided", "placeholder"}).
    // `proposed` (speaker-*, avatar-*) and `pending` (card-rest) stay out per PLAN.md §2.1.
    static let groundEntry        = Entry(id: "ground",         swiftName: "ground",        light: "#F5F4EF",   dark: "#070B11")
    static let surfaceEntry       = Entry(id: "surface",        swiftName: "surface",       light: "#FFFFFF",   dark: "#10151C")
    static let sunkenEntry        = Entry(id: "sunken",         swiftName: "sunken",        light: "#ECEAE3",   dark: "#0B1016")
    static let raisedEntry        = Entry(id: "raised",         swiftName: "raised",        light: "#FFFFFF",   dark: "#181E26")
    static let lineEntry          = Entry(id: "line",           swiftName: "line",          light: "#D9D6CD",   dark: "#232932")
    static let lineSoftEntry      = Entry(id: "line-soft",      swiftName: "lineSoft",      light: "#E6E3DB",   dark: "#1A1F27")
    static let inkEntry           = Entry(id: "ink",            swiftName: "ink",           light: "#1A1611",   dark: "#E5E5D9")
    static let ink2Entry          = Entry(id: "ink-2",          swiftName: "ink2",          light: "#5B544A",   dark: "#AFAEA4")
    static let ink3Entry          = Entry(id: "ink-3",          swiftName: "ink3",          light: "#726B61",   dark: "#88877C")
    static let accentEntry        = Entry(id: "accent",         swiftName: "accent",        light: "#007999",   dark: "#83CDDF")
    static let accentStrongEntry  = Entry(id: "accent-strong",  swiftName: "accentStrong",  light: "#006380",   dark: "#83CDDF")
    static let onAccentEntry      = Entry(id: "on-accent",      swiftName: "onAccent",      light: "#FFFFFF",   dark: "#070B11")
    static let accentInkEntry     = Entry(id: "accent-ink",     swiftName: "accentInk",     light: "#006380",   dark: "#83CDDF")
    static let accentTintEntry    = Entry(id: "accent-tint",    swiftName: "accentTint",    light: "#C9EBF8",   dark: "#072930")
    static let recordEntry        = Entry(id: "record",         swiftName: "record",        light: "#C01C28",   dark: "#C01C28")
    static let recordInkEntry     = Entry(id: "record-ink",     swiftName: "recordInk",     light: "#C01C28",   dark: "#FF7B7F")
    static let recordTintEntry    = Entry(id: "record-tint",    swiftName: "recordTint",    light: "#FBE4E6",   dark: "#3A1A1D")
    static let onRecordEntry      = Entry(id: "on-record",      swiftName: "onRecord",      light: "#FFFFFF",   dark: "#FFFFFF")
    static let errorEntry         = Entry(id: "error",          swiftName: "error",         light: "#C12B0B",   dark: "#FF6F4C")
    static let errorTintEntry     = Entry(id: "error-tint",     swiftName: "errorTint",     light: "#FFE8E2",   dark: "#3F1A12")
    static let successEntry       = Entry(id: "success",        swiftName: "success",       light: "#197640",   dark: "#49BA71")
    static let successTintEntry   = Entry(id: "success-tint",   swiftName: "successTint",   light: "#E0F5E5",   dark: "#0E2B18")
    static let warnInkEntry       = Entry(id: "warn-ink",       swiftName: "warnInk",       light: "#774A00",   dark: "#FCB700")
    static let warnTintEntry      = Entry(id: "warn-tint",      swiftName: "warnTint",      light: "#FFECC9",   dark: "#342305")
    static let neutralInkEntry    = Entry(id: "neutral-ink",    swiftName: "neutralInk",    light: "#5B544A",   dark: "#AFAEA4")
    static let neutralTintEntry   = Entry(id: "neutral-tint",   swiftName: "neutralTint",   light: "#EBE9E2",   dark: "#1A1F27")
    static let highlightEntry     = Entry(id: "highlight",      swiftName: "highlight",     light: "#BDDCE4",   dark: "#3E5F6A")
    static let highlightInkEntry  = Entry(id: "highlight-ink",  swiftName: "highlightInk",  light: "#1A1611",   dark: "#E5E5D9")
    static let inverseEntry       = Entry(id: "inverse",        swiftName: "inverse",       light: "#10151C",   dark: "#E5E5D9")
    static let onInverseEntry     = Entry(id: "on-inverse",     swiftName: "onInverse",     light: "#E5E5D9",   dark: "#070B11")
    static let inverseAccentEntry = Entry(id: "inverse-accent", swiftName: "inverseAccent", light: "#83CDDF",   dark: "#006380")
    static let scrimEntry         = Entry(id: "scrim",          swiftName: "scrim",         light: "#070B1173", dark: "#00000099")
    static let shadowEntry        = Entry(id: "shadow",         swiftName: "shadow",        light: "#0F05001F", dark: "#00000066")

    static let entries: [Entry] = [
        groundEntry, surfaceEntry, sunkenEntry, raisedEntry, lineEntry, lineSoftEntry,
        inkEntry, ink2Entry, ink3Entry,
        accentEntry, accentStrongEntry, onAccentEntry, accentInkEntry, accentTintEntry,
        recordEntry, recordInkEntry, recordTintEntry, onRecordEntry,
        errorEntry, errorTintEntry, successEntry, successTintEntry,
        warnInkEntry, warnTintEntry, neutralInkEntry, neutralTintEntry,
        highlightEntry, highlightInkEntry,
        inverseEntry, onInverseEntry, inverseAccentEntry, scrimEntry, shadowEntry,
    ]

    enum ns {
        static let ground        = groundEntry.nsColor
        static let surface       = surfaceEntry.nsColor
        static let sunken        = sunkenEntry.nsColor
        static let raised        = raisedEntry.nsColor
        static let line          = lineEntry.nsColor
        static let lineSoft      = lineSoftEntry.nsColor
        static let ink           = inkEntry.nsColor
        static let ink2          = ink2Entry.nsColor
        static let ink3          = ink3Entry.nsColor
        static let accent        = accentEntry.nsColor
        static let accentStrong  = accentStrongEntry.nsColor
        static let onAccent      = onAccentEntry.nsColor
        static let accentInk     = accentInkEntry.nsColor
        static let accentTint    = accentTintEntry.nsColor
        static let record        = recordEntry.nsColor
        static let recordInk     = recordInkEntry.nsColor
        static let recordTint    = recordTintEntry.nsColor
        static let onRecord      = onRecordEntry.nsColor
        static let error         = errorEntry.nsColor
        static let errorTint     = errorTintEntry.nsColor
        static let success       = successEntry.nsColor
        static let successTint   = successTintEntry.nsColor
        static let warnInk       = warnInkEntry.nsColor
        static let warnTint      = warnTintEntry.nsColor
        static let neutralInk    = neutralInkEntry.nsColor
        static let neutralTint   = neutralTintEntry.nsColor
        static let highlight     = highlightEntry.nsColor
        static let highlightInk  = highlightInkEntry.nsColor
        static let inverse       = inverseEntry.nsColor
        static let onInverse     = onInverseEntry.nsColor
        static let inverseAccent = inverseAccentEntry.nsColor
        static let scrim         = scrimEntry.nsColor
        static let shadow        = shadowEntry.nsColor
    }

    static let ground        = groundEntry.color
    static let surface       = surfaceEntry.color
    static let sunken        = sunkenEntry.color
    static let raised        = raisedEntry.color
    static let line          = lineEntry.color
    static let lineSoft      = lineSoftEntry.color
    static let ink           = inkEntry.color
    static let ink2          = ink2Entry.color
    static let ink3          = ink3Entry.color
    static let accent        = accentEntry.color
    static let accentStrong  = accentStrongEntry.color
    static let onAccent      = onAccentEntry.color
    static let accentInk     = accentInkEntry.color
    static let accentTint    = accentTintEntry.color
    static let record        = recordEntry.color
    static let recordInk     = recordInkEntry.color
    static let recordTint    = recordTintEntry.color
    static let onRecord      = onRecordEntry.color
    static let error         = errorEntry.color
    static let errorTint     = errorTintEntry.color
    static let success       = successEntry.color
    static let successTint   = successTintEntry.color
    static let warnInk       = warnInkEntry.color
    static let warnTint      = warnTintEntry.color
    static let neutralInk    = neutralInkEntry.color
    static let neutralTint   = neutralTintEntry.color
    static let highlight     = highlightEntry.color
    static let highlightInk  = highlightInkEntry.color
    static let inverse       = inverseEntry.color
    static let onInverse     = onInverseEntry.color
    static let inverseAccent = inverseAccentEntry.color
    static let scrim         = scrimEntry.color
    static let shadow        = shadowEntry.color

    static func parseSRGB(_ hex: String) -> NSColor {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        precondition(digits.count == 6 || digits.count == 8, "Invalid token hex: \(hex)")
        var raw: UInt64 = 0
        let ok = Scanner(string: digits).scanHexInt64(&raw)
        precondition(ok, "Non-hex token: \(hex)")
        if digits.count == 6 {
            let r = CGFloat((raw >> 16) & 0xFF) / 255
            let g = CGFloat((raw >> 8) & 0xFF) / 255
            let b = CGFloat(raw & 0xFF) / 255
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        } else {
            let r = CGFloat((raw >> 24) & 0xFF) / 255
            let g = CGFloat((raw >> 16) & 0xFF) / 255
            let b = CGFloat((raw >> 8) & 0xFF) / 255
            let a = CGFloat(raw & 0xFF) / 255
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
    }

    static func dynamicSRGB(light: String, dark: String) -> NSColor {
        let lightColor = parseSRGB(light)
        let darkColor = parseSRGB(dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        }
    }

    static func camelCaseName(for tokenID: String) -> String {
        let parts = tokenID.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first else { return tokenID }
        return first + parts.dropFirst().map { part in
            guard let head = part.first else { return "" }
            return String(head).uppercased() + part.dropFirst()
        }.joined()
    }

    static func resolvedHex(_ color: NSColor, dark: Bool, includeAlpha: Bool) -> String? {
        guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { return nil }
        var srgb: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            srgb = color.usingColorSpace(.sRGB)
        }
        guard let resolved = srgb else { return nil }
        func byte(_ c: CGFloat) -> Int { Int((min(1, max(0, c)) * 255).rounded()) }
        let r = byte(resolved.redComponent)
        let g = byte(resolved.greenComponent)
        let b = byte(resolved.blueComponent)
        let a = byte(resolved.alphaComponent)
        return includeAlpha ? String(format: "#%02X%02X%02X%02X", r, g, b, a) : String(format: "#%02X%02X%02X", r, g, b)
    }

    static func verifySync(tokensData: Data, upstreamData: Data, sheet: [Entry] = entries) -> Bool {
        struct UpstreamPin: Decodable {
            let repository: String
            let path: String
            let commit: String
            let sha256: String
        }
        struct TokenSpec: Decodable {
            let light: String
            let dark: String
            let status: String
        }
        struct TokenFile: Decodable {
            let schema: String
            let modes: [String]
            let tokens: [String: TokenSpec]
        }
        guard let pin = try? JSONDecoder().decode(UpstreamPin.self, from: upstreamData),
              pin.repository == upstreamRepository,
              pin.path == upstreamPath,
              pin.commit == upstreamCommit else { return false }
        let digest = SHA256.hash(data: tokensData).map { String(format: "%02x", $0) }.joined()
        guard digest == pin.sha256.lowercased(),
              let file = try? JSONDecoder().decode(TokenFile.self, from: tokensData),
              file.schema == "cassini-ux/brand-tokens@1",
              file.modes == ["light", "dark"] else { return false }

        let active = file.tokens.filter { $0.value.status == "decided" || $0.value.status == "placeholder" }
        let byID = Dictionary(uniqueKeysWithValues: sheet.map { ($0.id, $0) })
        guard byID.count == sheet.count, byID.count == active.count else { return false }
        for (id, spec) in active {
            guard let entry = byID[id],
                  entry.swiftName == camelCaseName(for: id) else { return false }
            let wantLight = spec.light.uppercased()
            let wantDark = spec.dark.uppercased()
            guard entry.light.uppercased() == wantLight,
                  entry.dark.uppercased() == wantDark,
                  resolvedHex(entry.nsColor, dark: false, includeAlpha: wantLight.count == 9) == wantLight,
                  resolvedHex(entry.nsColor, dark: true, includeAlpha: wantDark.count == 9) == wantDark else { return false }
        }
        return true
    }

    #if DEBUG
    static func nativeSelfTest(tokensURL: URL? = Bundle.main.url(forResource: "tokens", withExtension: "json", subdirectory: "Brand"),
                               upstreamURL: URL? = Bundle.main.url(forResource: "UPSTREAM", withExtension: "json", subdirectory: "Brand")) -> [String: Bool] {
        guard let tokensURL, let upstreamURL,
              let tokensData = try? Data(contentsOf: tokensURL),
              let upstreamData = try? Data(contentsOf: upstreamURL) else {
            return ["brandTokensSynced": false, "brandTokensRejectsDrift": false]
        }
        let synced = verifySync(tokensData: tokensData, upstreamData: upstreamData)
        var driftedLight = entries
        driftedLight[0] = Entry(id: driftedLight[0].id, swiftName: driftedLight[0].swiftName, light: "#000000", dark: driftedLight[0].dark)
        var driftedDark = entries
        driftedDark[9] = Entry(id: driftedDark[9].id, swiftName: driftedDark[9].swiftName, light: driftedDark[9].light, dark: "#FFFFFF")
        let dropped = Array(entries.dropLast())
        let badDigest = Data((String(data: upstreamData, encoding: .utf8) ?? "").replacingOccurrences(of: upstreamCommit, with: String(repeating: "0", count: 40)).utf8)
        let rejectsDrift = !verifySync(tokensData: tokensData, upstreamData: upstreamData, sheet: driftedLight)
            && !verifySync(tokensData: tokensData, upstreamData: upstreamData, sheet: driftedDark)
            && !verifySync(tokensData: tokensData, upstreamData: upstreamData, sheet: dropped)
            && !verifySync(tokensData: tokensData, upstreamData: badDigest)
        return ["brandTokensSynced": synced, "brandTokensRejectsDrift": rejectsDrift]
    }
    #endif
}

/// Semantic colour roles for the macOS app, backed by `CassiniTokens` (Wave 1 decided palette).
/// Open canvas items (`C16` desktop sidebar, `L-14` speaker hues, `L-12` spectrogram) remain untouched.
enum CassiniTheme {
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: adaptiveNS(light: light, dark: dark))
    }

    private static func adaptiveNS(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    // Scene tint (MAC-TOK-02, L-06, L-18)
    static let sceneTint: Color? = CassiniTokens.accent

    // Grounds & surfaces (MAC-TOK-03, L-16, L-18; desktop sidebar stays platform colour until C16 is answered)
    static let paneGround = CassiniTokens.ground
    static let nsPaneGround: NSColor = CassiniTokens.ns.ground
    static let windowGround = CassiniTokens.ground
    static let sidebarGround = adaptive(
        light: NSColor(red: 241/255, green: 240/255, blue: 245/255, alpha: 1),
        dark: .windowBackgroundColor
    )
    static let surface = CassiniTokens.surface
    static let nsChipFill: NSColor = CassiniTokens.ns.neutralTint
    static let chipFill = CassiniTokens.neutralTint
    static let controlFill = CassiniTokens.surface
    static let subtleWash = CassiniTokens.sunken
    static let ratePillFill = CassiniTokens.neutralTint

    // Lines & borders (MAC-TOK-03, L-16, L-18)
    static let cardStroke = CassiniTokens.line
    static let modelCardStroke = CassiniTokens.line
    static let tagStroke = CassiniTokens.line
    static let secondaryTagStroke = CassiniTokens.line
    static let nsSeparator: NSColor = CassiniTokens.ns.line

    // Inks (MAC-TOK-03, L-16, L-18)
    static let ink = CassiniTokens.ink
    static let nsInk: NSColor = CassiniTokens.ns.ink
    static let primaryInk = CassiniTokens.ink
    static let ink2 = CassiniTokens.ink2
    static let secondaryInk = CassiniTokens.ink2
    static let nsInk2: NSColor = CassiniTokens.ns.ink2
    static let nsInk3: NSColor = CassiniTokens.ns.ink3
    static let nsUpcomingWordInk: NSColor = CassiniTokens.ns.ink3
    static func nsInactiveChipFill(dark: Bool) -> NSColor {
        CassiniTokens.neutralTintEntry.resolvedNSColor(dark: dark)
    }

    // Accents (MAC-TOK-02, L-06, L-18)
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

    // Highlights (MAC-TOK-04, L-24)
    static let nsHighlight: NSColor = CassiniTokens.ns.highlight
    static let nsSearchHighlight: NSColor = CassiniTokens.ns.highlight
    static let nsHighlightInk: NSColor? = CassiniTokens.ns.highlightInk
    static let nsSelectedSearchHighlight = adaptiveNS(
        light: NSColor.white.withAlphaComponent(0.28),
        dark: NSColor.black.withAlphaComponent(0.14)
    )
    static func nsLegacyMatchFill(dark: Bool, isCurrent: Bool) -> NSColor {
        CassiniTokens.highlightEntry.resolvedNSColor(dark: dark).withAlphaComponent(isCurrent ? 1.0 : 0.65)
    }

    // Record roles (MAC-TOK-05, L-20; L-07 placeholder #C01C28)
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

    // Status & inverse roles (MAC-TOK-07, L-16, L-26)
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
    static let stepDoneFill = CassiniTokens.success
    static let onSuccess = CassiniTokens.onAccent
    static let error = CassiniTokens.error
    static let errorTint = CassiniTokens.errorTint
    static let inverse = CassiniTokens.inverse
    static let onInverse = CassiniTokens.onInverse
    static let inverseAccent = CassiniTokens.inverseAccent
    static let scrim = CassiniTokens.scrim
    static let shadow = CassiniTokens.shadow
    static let toastUsesInverse = true

    // App-local speaker hues while L-14 is OPEN (PLAN.md §2.1: do not read `proposed` speaker-* tokens;
    // MAC-TOK-02/09: decouple Speaker 1 from scene accent so it stays app-local blue instead of turning teal)
    static func speakerColour(_ index: Int) -> Color {
        [Color(nsColor: .systemBlue), Color(red: 179/255, green: 71/255, blue: 0), Color(red: 125/255, green: 60/255, blue: 152/255)][index % 3]
    }
    static let legacySpeakerPalette: [NSColor] = [.systemOrange, .systemIndigo, .systemTeal, .systemGreen, .systemPink]
}
