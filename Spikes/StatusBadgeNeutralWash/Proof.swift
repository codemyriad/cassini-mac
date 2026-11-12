// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import Darwin

private let labels = ["Recording 12:48", "Importing…", "Saving…", "Transcribing…", "Needs attention", "Interrupted", "Received"]
private func hosts(dark: Bool) -> [(String, NSColor)] {
    [("Ground", CassiniTokens.groundEntry.resolvedNSColor(dark: dark)),
     ("Resting card", MeetingCardPaint(dark: dark, selected: false).fill),
     ("Selected card", MeetingCardPaint(dark: dark, selected: true).fill)]
}
private struct Board: View {
    let after: Bool
    let dark: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("W2.1 · L-46 · \(after ? "After: ink at 10%" : "Before: opaque neutral-tint")")
                .font(.system(size: 19, weight: .semibold))
            Text("Standalone component · frozen animation · \(dark ? "dark" : "light")")
                .font(.system(size: 12))
            HStack(alignment: .top, spacing: 16) {
                ForEach(hosts(dark: dark), id: \.0) { name, background in
                    VStack(alignment: .leading, spacing: 16) {
                        Text(name).font(.system(size: 12, weight: .semibold))
                        ForEach(Array(StatusBadgeKind.allCases.enumerated()), id: \.offset) { index, kind in
                            Group {
                                if after {
                                    MeetingStatusBadge(kind: kind, label: labels[index], isAnimating: false)
                                } else {
                                    PreviousMeetingStatusBadge(kind: PreviousStatusBadgeKind(rawValue: kind.rawValue)!, label: labels[index], isAnimating: false)
                                }
                            }.frame(height: 24)
                        }
                    }.padding(18).frame(width: 235, alignment: .leading)
                        .background(Color(nsColor: background))
                }
            }
            Text("Neutral wash follows the host surface. Recording, warnings and Received are unchanged.")
                .font(.system(size: 11))
        }.padding(22)
            .foregroundStyle(Color(nsColor: CassiniTokens.inkEntry.resolvedNSColor(dark: dark)))
            .background(Color(nsColor: CassiniTokens.groundEntry.resolvedNSColor(dark: dark)))
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
        var results: [[String: Any]] = []
        func rgb(_ color: NSColor) -> [Double] {
            let c = color.usingColorSpace(.sRGB)!
            return [c.redComponent, c.greenComponent, c.blueComponent].map { Double($0)*255 }
        }
        for dark in [false, true] {
            var failure: Error?
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                do {
                    for (index, kind) in StatusBadgeKind.allCases.enumerated() {
                        let neutral = [.importing, .saving, .transcribing].contains(kind)
                        let badge = MeetingStatusBadge(kind: kind, label: labels[index], isAnimating: false)
                        let bare = try image(badge, dark: dark)
                        let bytes = pixels(bare)
                        let sample = ((bare.height/2)*bare.width + bare.width-8)*4
                        try require(bare.height == 36, "Badge height changed")
                        if neutral {
                            let ink = rgb(CassiniTokens.inkEntry.resolvedNSColor(dark: dark))
                            try require(abs(Int(bytes[sample+3])-26) <= 1, "Neutral fill must have 10% alpha")
                            try require((0..<3).allSatisfy { abs(Double(bytes[sample+$0])-ink[$0]*0.1) <= 1 }, "Neutral fill must use ink")
                            let glyphInk = rgb(CassiniTokens.ink2Entry.resolvedNSColor(dark: dark))
                            let opaqueInk = stride(from: 0, to: bytes.count, by: 4).contains { offset in
                                bytes[offset+3] == 255 && (0..<3).allSatisfy { abs(Double(bytes[offset+$0])-glyphInk[$0]) <= 2 }
                            }
                            try require(opaqueInk, "Neutral text and glyph must remain opaque")
                        }
                        for (host, background) in hosts(dark: dark) {
                            let current = try image(badge.background(Color(nsColor: background)), dark: dark)
                            let rgba = pixels(current)
                            if neutral {
                                let ink = rgb(CassiniTokens.inkEntry.resolvedNSColor(dark: dark))
                                let base = rgb(background)
                                try require(rgba[sample+3] == 255 && (0..<3).allSatisfy {
                                    abs(Double(rgba[sample+$0])-(ink[$0]*0.1+base[$0]*0.9)) <= 2
                                }, "Neutral fill must composite over \(host)")
                            } else {
                                let previous = PreviousMeetingStatusBadge(kind: PreviousStatusBadgeKind(rawValue: kind.rawValue)!, label: labels[index], isAnimating: false)
                                let old = try image(previous.background(Color(nsColor: background)), dark: dark)
                                let oldPixels = pixels(old)
                                let differences = zip(rgba, oldPixels).filter { $0 != $1 }
                                try require(current.width == old.width && differences.allSatisfy { abs(Int($0.0)-Int($0.1)) <= 1 }, "Non-neutral badge changed: \(kind), \(differences.count) differing channels; max \(differences.map { abs(Int($0.0)-Int($0.1)) }.max() ?? 0)")
                            }
                            results.append(["kind": kind.rawValue, "dark": dark, "host": host,
                                            "check": neutral ? "ink 10% compositing; opaque foreground" : "matches previous component within 1/255 raster rounding"])
                        }
                    }
                    for after in [false, true] {
                        let cg = try image(Board(after: after, dark: dark), dark: dark)
                        try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
                            .write(to: output.appendingPathComponent("\(after ? "after" : "before")-\(dark ? "dark" : "light").png"))
                    }
                } catch { failure = error }
            }
            if let failure { throw failure }
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("checks.json"))
        print("All 42 badge/scheme/host cases pass: neutral ink at 10%, opaque foreground, unchanged non-neutral badges")
    }
}
