// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import XCTest

/// Pixel-sampling helper over a captured window screenshot.
/// All coordinates passed in are in macOS window-relative points (top-left origin,
/// matching `XCUIElement.frame` offset by `window.frame.origin`).
struct PixelImage {
    struct RGB {
        let r: Double
        let g: Double
        let b: Double

        func maxChannelDiff(to other: RGB) -> Double {
            max(abs(r - other.r), max(abs(g - other.g), abs(b - other.b)))
        }

        /// Hue in degrees [0, 360) and HSV saturation [0, 1].
        var hueAndSaturation: (hue: Double, saturation: Double) {
            let rn = r / 255.0, gn = g / 255.0, bn = b / 255.0
            let maxC = max(rn, max(gn, bn))
            let minC = min(rn, min(gn, bn))
            let delta = maxC - minC
            let sat = maxC > 0 ? delta / maxC : 0
            var hue: Double = 0
            if delta > 1e-6 {
                if maxC == rn {
                    hue = 60.0 * (((gn - bn) / delta).truncatingRemainder(dividingBy: 6.0))
                } else if maxC == gn {
                    hue = 60.0 * (((bn - rn) / delta) + 2.0)
                } else {
                    hue = 60.0 * (((rn - gn) / delta) + 4.0)
                }
                if hue < 0 { hue += 360.0 }
            }
            return (hue, sat)
        }

        /// Accent-blue check: hue 200–230°, saturation > 0.35.
        var isAccentBlue: Bool {
            let (h, s) = hueAndSaturation
            return h >= 200.0 && h <= 230.0 && s > 0.35
        }
    }

    let width: Int
    let height: Int
    let scale: CGFloat
    let windowFrame: CGRect
    private let bytes: [UInt8]
    private let bytesPerRow: Int

    init(screenshot: XCUIScreenshot, windowFrame: CGRect) throws {
        let image = screenshot.image
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            throw NSError(domain: "PixelImage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not extract CGImage from screenshot"])
        }
        self.width = cgImage.width
        self.height = cgImage.height
        self.windowFrame = windowFrame
        self.scale = windowFrame.width > 0 ? CGFloat(cgImage.width) / windowFrame.width : 1.0
        self.bytesPerRow = width * 4
        var raw = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &raw,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw NSError(domain: "PixelImage", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create RGBA bitmap context"])
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.bytes = raw
    }

    /// Converts screen-space XCUIElement rect into window-relative points.
    func windowRect(for screenRect: CGRect) -> CGRect {
        CGRect(
            x: screenRect.minX - windowFrame.minX,
            y: screenRect.minY - windowFrame.minY,
            width: screenRect.width,
            height: screenRect.height
        )
    }

    func pixelColor(px: Int, py: Int) -> RGB {
        let cx = max(0, min(width - 1, px))
        let cy = max(0, min(height - 1, py))
        let offset = cy * bytesPerRow + cx * 4
        return RGB(r: Double(bytes[offset]), g: Double(bytes[offset + 1]), b: Double(bytes[offset + 2]))
    }

    func color(atPoint pt: CGPoint) -> RGB {
        pixelColor(px: Int((pt.x * scale).rounded()), py: Int((pt.y * scale).rounded()))
    }

    func meanColor(inPointRect rect: CGRect) -> RGB {
        let x0 = max(0, Int((rect.minX * scale).rounded(.down)))
        let y0 = max(0, Int((rect.minY * scale).rounded(.down)))
        let x1 = min(width, Int((rect.maxX * scale).rounded(.up)))
        let y1 = min(height, Int((rect.maxY * scale).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return RGB(r: 0, g: 0, b: 0) }
        var sr = 0.0, sg = 0.0, sb = 0.0
        var count = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let c = pixelColor(px: x, py: y)
                sr += c.r; sg += c.g; sb += c.b
                count += 1
            }
        }
        let n = Double(max(1, count))
        return RGB(r: sr / n, g: sg / n, b: sb / n)
    }

    func colorVariance(inPointRect rect: CGRect) -> Double {
        let mean = meanColor(inPointRect: rect)
        let x0 = max(0, Int((rect.minX * scale).rounded(.down)))
        let y0 = max(0, Int((rect.minY * scale).rounded(.down)))
        let x1 = min(width, Int((rect.maxX * scale).rounded(.up)))
        let y1 = min(height, Int((rect.maxY * scale).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return 0 }
        var sumSq = 0.0
        var count = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let c = pixelColor(px: x, py: y)
                sumSq += pow(c.r - mean.r, 2) + pow(c.g - mean.g, 2) + pow(c.b - mean.b, 2)
                count += 1
            }
        }
        return sumSq / Double(max(1, count * 3))
    }

    func containsAccentBlue(inPointRect rect: CGRect) -> Bool {
        let x0 = max(0, Int((rect.minX * scale).rounded(.down)))
        let y0 = max(0, Int((rect.minY * scale).rounded(.down)))
        let x1 = min(width, Int((rect.maxX * scale).rounded(.up)))
        let y1 = min(height, Int((rect.maxY * scale).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return false }
        for y in y0..<y1 {
            for x in x0..<x1 {
                if pixelColor(px: x, py: y).isAccentBlue { return true }
            }
        }
        return false
    }

    /// Returns the longest contiguous horizontal run (in points) of pixels matching `predicate` on row `yPt`.
    func longestHorizontalRun(atY yPt: CGFloat, fromX xStartPt: CGFloat, toX xEndPt: CGFloat, matching predicate: (RGB) -> Bool) -> CGFloat {
        let py = max(0, min(height - 1, Int((yPt * scale).rounded())))
        let x0 = max(0, Int((xStartPt * scale).rounded(.down)))
        let x1 = min(width, Int((xEndPt * scale).rounded(.up)))
        guard x1 > x0 else { return 0 }
        var best = 0
        var current = 0
        for x in x0..<x1 {
            if predicate(pixelColor(px: x, py: py)) {
                current += 1
                if current > best { best = current }
            } else {
                current = 0
            }
        }
        return CGFloat(best) / scale
    }

    /// Scans horizontally inside `rect` to find the leftmost and rightmost x (in window points)
    /// where pixels differ from `ground` by more than `threshold`.
    func drawnHorizontalBounds(inPointRect rect: CGRect, against ground: RGB, threshold: Double = 6) -> (left: CGFloat, right: CGFloat)? {
        let x0 = max(0, Int((rect.minX * scale).rounded(.down)))
        let y0 = max(0, Int((rect.minY * scale).rounded(.down)))
        let x1 = min(width, Int((rect.maxX * scale).rounded(.up)))
        let y1 = min(height, Int((rect.maxY * scale).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        var minFound: Int?
        var maxFound: Int?
        for x in x0..<x1 {
            var differs = false
            for y in y0..<y1 {
                if pixelColor(px: x, py: y).maxChannelDiff(to: ground) > threshold {
                    differs = true
                    break
                }
            }
            if differs {
                if minFound == nil { minFound = x }
                maxFound = x
            }
        }
        guard let left = minFound, let right = maxFound else { return nil }
        return (CGFloat(left) / scale, CGFloat(right + 1) / scale)
    }

    /// Fraction of pixels on row `yPt` within `[xStartPt, xEndPt]` differing from `ground` by more than `threshold`.
    func rowDifferenceFraction(atY yPt: CGFloat, fromX xStartPt: CGFloat, toX xEndPt: CGFloat, against ground: RGB, threshold: Double = 6) -> Double {
        let py = max(0, min(height - 1, Int((yPt * scale).rounded())))
        let x0 = max(0, Int((xStartPt * scale).rounded(.down)))
        let x1 = min(width, Int((xEndPt * scale).rounded(.up)))
        guard x1 > x0 else { return 0 }
        var diffCount = 0
        for x in x0..<x1 {
            if pixelColor(px: x, py: py).maxChannelDiff(to: ground) > threshold {
                diffCount += 1
            }
        }
        return Double(diffCount) / Double(x1 - x0)
    }

    /// Maximum contrast against `ground` across pixels in `rect`.
    func maxContrast(inPointRect rect: CGRect, against ground: RGB) -> Double {
        let x0 = max(0, Int((rect.minX * scale).rounded(.down)))
        let y0 = max(0, Int((rect.minY * scale).rounded(.down)))
        let x1 = min(width, Int((rect.maxX * scale).rounded(.up)))
        let y1 = min(height, Int((rect.maxY * scale).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return 0 }
        var best = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let d = pixelColor(px: x, py: y).maxChannelDiff(to: ground)
                if d > best { best = d }
            }
        }
        return best
    }
}

/// Shared base class for Beta 19 acceptance tests (D-1195).
class AcceptanceTestCase: XCTestCase {
    func expectStrictFailure(_ reason: String, _ block: () throws -> Void) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        XCTExpectFailure(reason, options: options) {
            do {
                try block()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor func launchAcceptance(
        _ name: String,
        fixture: String,
        size: String = "1120x720",
        dark: Bool = false,
        extra: [String] = []
    ) throws -> XCUIApplication {
        let app = XCUIApplication()
        let root = try fixtureDirectory().appendingPathComponent("Library/" + fixture)
        app.launchEnvironment["CASSINI_HOSTED_SCREENSHOTS"] = "1"
        app.launchArguments = [
            "-CassiniScreenshot", name,
            "-CassiniFixture", root.path,
            "-CassiniScreenshotSize", size,
            "-CassiniNow", "2026-10-27T13:18:00Z",
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(en-GB)",
            "-AppleLocale", "en_GB",
            "-AppleInterfaceStyle", dark ? "Dark" : "Light",
        ]
        if dark {
            app.launchArguments += ["-CassiniScreenshotScheme", "dark"]
        }
        if !extra.contains("-CassiniSettingsID") && !extra.contains("-CassiniCaptureID") && !extra.contains("-CassiniDefaultsID") {
            app.launchArguments += ["-CassiniDefaultsID", UUID().uuidString]
        }
        app.launchArguments += extra
        if extra.contains("--fixture-library-recording"), !extra.contains("-CassiniDiskFree") {
            app.launchArguments += ["-CassiniDiskFree", String(20 << 30), "-CassiniDiskTotal", String(100 << 30)]
        }
        app.launch()
        if extra.contains("--fixture-library-recording") || extra.contains("--fixture-library-rename"),
           !app.windows.firstMatch.waitForExistence(timeout: 2) {
            app.menuBars.menuBarItems["Window"].click()
            app.menuBars.menuBarItems["Window"].menus.menuItems["Cassini talk"].click()
        }
        return app
    }

    @MainActor func attachWindowScreenshot(_ element: XCUIElement, name: String) -> XCUIScreenshot {
        let shot = element.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return shot
    }

    @MainActor func attachSideBySide(_ left: XCUIScreenshot, _ right: XCUIScreenshot, name: String) {
        let lImg = left.image, rImg = right.image
        let totalWidth = lImg.size.width + rImg.size.width + 16
        let totalHeight = max(lImg.size.height, rImg.size.height)
        let combined = NSImage(size: NSSize(width: totalWidth, height: totalHeight))
        combined.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: combined.size).fill()
        lImg.draw(in: NSRect(x: 0, y: totalHeight - lImg.size.height, width: lImg.size.width, height: lImg.size.height))
        rImg.draw(in: NSRect(x: lImg.size.width + 16, y: totalHeight - rImg.size.height, width: rImg.size.width, height: rImg.size.height))
        combined.unlockFocus()
        if let tiff = combined.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func hasKeyboardFocus(_ element: XCUIElement) -> Bool {
        (element.value(forKey: "hasKeyboardFocus") as? Bool) == true
    }

    func sidebarSearchField(in window: XCUIElement) -> XCUIElement {
        let byId = window.searchFields["library-search-field"].firstMatch
        if byId.exists { return byId }
        return window.searchFields.firstMatch
    }

    func visibleText(_ element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    func waitFor(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let exp = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        return XCTWaiter.wait(for: [exp], timeout: timeout) == .completed
    }

    func fixtureDirectory() throws -> URL {
        var ancestor = Bundle(for: Self.self).bundleURL
        for _ in 0..<8 {
            let directory = ancestor.appendingPathComponent("Cassini.app/Contents/Resources/Fixtures")
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Library/main/activity.json").path) {
                return directory
            }
            ancestor.deleteLastPathComponent()
        }
        throw NSError(domain: "CassiniAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixtures/Library/main not found"])
    }
}
