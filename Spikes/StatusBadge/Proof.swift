// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import Darwin

private let labels: [String] = ["Recording 12:48", "Importing…", "Saving…",
    "Transcribing, about 4 minutes left", "Needs attention", "Interrupted at 00:41:12", "Received"]

private struct BadgeBoard: View {
    let after: Bool
    let dark: Bool
    private func color(_ entry: CassiniTokens.Entry) -> Color {
        Color(nsColor: entry.resolvedNSColor(dark: dark))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(after ? "W2.1 · status badge component" : "Before · existing badgePill renderer")
                .font(.system(size: 18, weight: .semibold))
            Text("Standalone proof · same caller labels · \(dark ? "dark" : "light")")
                .font(.system(size: 12)).foregroundStyle(color(CassiniTokens.ink2Entry))
            ForEach(Array(StatusBadgeKind.allCases.enumerated()), id: \.offset) { index, kind in
                HStack(spacing: 14) {
                    Text(kind.rawValue).font(.system(size: 11)).frame(width: 95, alignment: .leading)
                        .foregroundStyle(color(CassiniTokens.ink3Entry))
                    if after {
                        MeetingStatusBadge(kind: kind, label: labels[index], isAnimating: false)
                    } else {
                        LegacyBadge(badge: MeetingBadge(text: labels[index],
                            tint: kind == .recording ? "red" : [.attention, .interrupted].contains(kind) ? "amber" : kind == .transcribing ? "accent" : "grey",
                            dot: kind == .recording ? true : nil))
                            .font(.system(size: 11.5))
                    }
                    Spacer(minLength: 0)
                }.frame(height: 28)
            }
            Text("Importing is a visual fixture, not a new app state. No app wiring or label change.")
                .font(.system(size: 11)).foregroundStyle(color(CassiniTokens.ink2Entry))
        }
        .padding(22).frame(width: 620, alignment: .leading)
        .foregroundStyle(color(CassiniTokens.inkEntry))
        .background(color(CassiniTokens.groundEntry))
    }
}

@main private struct Proof {
    @MainActor private static func image<V: View>(_ view: V, dark: Bool) throws -> CGImage {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        renderer.colorMode = .nonLinear
        guard let image = renderer.cgImage else { throw Failure("SwiftUI did not render the component") }
        return image
    }
    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message) }
    }
    private static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    @MainActor static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("Badge proof failed: \(error)\n".utf8))
            exit(1)
        }
    }
    @MainActor private static func run() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let expectedRoles: [(String, String?)] = [("record-ink", "record-tint"), ("ink-2", "neutral-tint"),
            ("ink-2", "neutral-tint"), ("ink-2", "neutral-tint"), ("warn-ink", "warn-tint"),
            ("warn-ink", "warn-tint"), ("ink-2", nil)]
        let expectedGlyphs: [StatusBadgeKind.Glyph] = [.dot, .spinner, .spinner, .spinner, .alert, .alert, .incoming]
        var results: [[String: Any]] = []
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            var failure: Error?
            appearance.performAsCurrentDrawingAppearance {
                do {
                    for (index, kind) in StatusBadgeKind.allCases.enumerated() {
                        try require(kind.ink.id == expectedRoles[index].0 && kind.fill?.id == expectedRoles[index].1,
                                    "Wrong canvas roles for \(kind)")
                        try require(kind.glyph == expectedGlyphs[index], "Wrong canvas glyph for \(kind)")
                        let badge = MeetingStatusBadge(kind: kind, label: labels[index], isAnimating: false)
                        let ordinary = try image(badge.foregroundStyle(Color(nsColor: CassiniTokens.inkEntry.resolvedNSColor(dark: dark))), dark: dark)
                        let selected = try image(badge.foregroundStyle(Color(nsColor: CassiniTokens.onAccentEntry.resolvedNSColor(dark: dark))), dark: dark)
                        try require(ordinary.height == 36, "Badge must be 18pt at 2x")
                        let rgba = pixels(ordinary)
                        try require(rgba == pixels(selected), "Inherited selection foreground changed \(kind)")
                        let interior = ((ordinary.height / 2) * ordinary.width + ordinary.width - 8) * 4
                        if let fill = kind.fill {
                            let rgb = dark ? fill.darkRGB : fill.lightRGB
                            let expected = [Int((rgb >> 16) & 255), Int((rgb >> 8) & 255), Int(rgb & 255)]
                            try require(rgba[interior + 3] == 255, "Tint is not opaque")
                            try require((0..<3).allSatisfy { abs(Int(rgba[interior + $0]) - expected[$0]) <= 1 }, "Tint differs from CassiniTokens for \(kind)")
                        } else {
                            try require(rgba[interior + 3] == 0, "Received must remain transparent inside its ring")
                            let ring = ((ordinary.height / 2) * ordinary.width + 1) * 4
                            try require(rgba[ring + 3] > 200, "Received outline is missing")
                        }
                        let glyphWidth = kind.glyph == .dot ? 6 : kind.glyph == .spinner ? 10 : 11
                        let inkRGB = dark ? kind.ink.darkRGB : kind.ink.lightRGB
                        let ink = [Int((inkRGB >> 16) & 255), Int((inkRGB >> 8) & 255), Int(inkRGB & 255)]
                        let hasGlyph = (0..<ordinary.height).contains { y in
                            (16..<(16 + glyphWidth * 2)).contains { x in
                                let offset = (y * ordinary.width + x) * 4
                                return rgba[offset + 3] > 200 && (0..<3).allSatisfy { abs(Int(rgba[offset + $0]) - ink[$0]) <= 4 }
                            }
                        }
                        try require(hasGlyph, "Glyph missing or not in its own ink for \(kind)")
                        results.append(["kind": kind.rawValue, "dark": dark, "heightPixels": ordinary.height,
                            "fill": kind.fill?.id ?? "none", "ink": kind.ink.id, "glyph": String(describing: kind.glyph), "selectionPixelsUnchanged": true])
                    }
                    for after in [false, true] {
                        let cg = try image(BadgeBoard(after: after, dark: dark), dark: dark)
                        let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
                        try png.write(to: output.appendingPathComponent("\(after ? "after" : "before")-\(dark ? "dark" : "light").png"))
                    }
                } catch { failure = error }
            }
            if let failure { throw failure }
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("checks.json"))
        print("All 14 badge/scheme cases pass: roles, 18pt height, token tint, transparent Received, selection-invariant pixels")
    }
}
