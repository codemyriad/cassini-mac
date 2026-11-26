// SPDX-License-Identifier: GPL-3.0-or-later
// Generates Cassini's macOS app icon assets from Cassini/Resources/Brand/saturn-nav.svg:
// - Cassini/AppIcon.icon (Icon Composer bundle for macOS 26+ Liquid Glass, solid #0D1015 fill)
// - Cassini/Assets.xcassets/AppIcon.appiconset (macOS 15 / Xcode 16.4 fallback PNGs with drop shadow)
//
// Usage (from repository root):
//   swift Artwork/generate-app-icon.swift
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let saturnSVGURL = root.appendingPathComponent("Cassini/Resources/Brand/saturn-nav.svg")
let iconBundleURL = root.appendingPathComponent("Cassini/AppIcon.icon", isDirectory: true)
let iconsetURL = root.appendingPathComponent("Cassini/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

// Approved 26 Nov 2026 spec (D-1174):
// - Ground: #0D1015 (brand token: ground, dark), flat, no gradient.
// - Saturn: saturn-nav.svg unchanged at every size.
// - Drawn outline in 184x120 box: x in [0.1, 177.2] (width 177.1, cx 88.65), y in [11, 108] (cy 59.5).
// - Placed at 74% of icon width, centred on that outline.
let saturnRaw = try String(contentsOf: saturnSVGURL, encoding: .utf8)
guard let openRange = saturnRaw.range(of: "<svg "),
      let openEnd = saturnRaw.range(of: ">", range: openRange.upperBound..<saturnRaw.endIndex)
else {
    fatalError("Unexpected saturn-nav.svg structure")
}
let saturnInner = String(saturnRaw[openEnd.upperBound...])

func placedSaturnSVG(canvasSize: Double, iconWidth: Double) -> String {
    let targetWidth = 0.74 * iconWidth
    let scale = targetWidth / 177.1
    let w = 184.0 * scale
    let h = 120.0 * scale
    let x = canvasSize / 2.0 - 88.65 * scale
    let y = canvasSize / 2.0 - 59.5 * scale
    return String(
        format: "<svg x=\"%.3f\" y=\"%.3f\" width=\"%.3f\" height=\"%.3f\" viewBox=\"0 0 184 120\" overflow=\"visible\">%@",
        x, y, w, h, saturnInner
    )
}

// 1. Write Cassini/AppIcon.icon (Icon Composer bundle, same foreground layer as iOS)
let iconAssetsURL = iconBundleURL.appendingPathComponent("Assets", isDirectory: true)
try FileManager.default.createDirectory(at: iconAssetsURL, withIntermediateDirectories: true)

let foregroundSVG = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\(placedSaturnSVG(canvasSize: 1024, iconWidth: 1024))</svg>
"""
try (foregroundSVG + "\n").write(
    to: iconAssetsURL.appendingPathComponent("cassini-icon-foreground-1024.svg"),
    atomically: true,
    encoding: .utf8
)

let iconJSON = """
{
  "fill" : {
    "solid" : "srgb:0.05098,0.06275,0.08235,1.00000"
  },
  "groups" : [
    {
      "layers" : [
        {
          "image-name" : "cassini-icon-foreground-1024.svg",
          "name" : "Saturn"
        }
      ],
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "translucency" : {
        "enabled" : true,
        "value" : 0.5
      }
    }
  ],
  "supported-platforms" : {
    "squares" : [
      "macOS"
    ]
  }
}
"""
try (iconJSON + "\n").write(
    to: iconBundleURL.appendingPathComponent("icon.json"),
    atomically: true,
    encoding: .utf8
)

// 2. Render macOS 15 fallback PNGs into AppIcon.appiconset (824x824 rounded square in 1024,
// corner radius 185.4, flat #0D1015 fill, Apple macOS template drop shadow, Saturn at 74% of 824).
let macOSFallbackSVG = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <filter id="macShadow" x="-15%" y="-15%" width="130%" height="130%">
      <feDropShadow dx="0" dy="10" stdDeviation="10" flood-color="#000000" flood-opacity="0.30"/>
    </filter>
  </defs>
  <rect x="100" y="100" width="824" height="824" rx="185.4" ry="185.4" fill="#0D1015" filter="url(#macShadow)"/>
  \(placedSaturnSVG(canvasSize: 1024, iconWidth: 824))
</svg>
"""

final class SVGRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var completion: ((CGImage) -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024), configuration: config)
        self.webView.setValue(false, forKey: "drawsBackground")
        super.init()
        self.webView.navigationDelegate = self
    }

    func render(svg: String) -> CGImage {
        var result: CGImage?
        self.completion = { image in
            result = image
        }
        let html = """
        <!doctype html>
        <html>
        <head><style>
        html, body { margin: 0; padding: 0; width: 1024px; height: 1024px; background: transparent; overflow: hidden; }
        svg { display: block; width: 1024px; height: 1024px; }
        </style></head>
        <body>\(svg)</body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
        let deadline = Date().addingTimeInterval(30)
        while result == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard let image = result else {
            fatalError("Timed out rendering SVG via WKWebView")
        }
        return image
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        config.snapshotWidth = NSNumber(value: 1024)
        webView.takeSnapshot(with: config) { image, error in
            if let error {
                fatalError("Snapshot failed: \(error)")
            }
            guard let image,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                fatalError("Failed to extract CGImage from snapshot")
            }
            self.completion?(cgImage)
        }
    }
}

_ = NSApplication.shared
let renderer = SVGRenderer()
let masterImage = renderer.render(svg: macOSFallbackSVG)

func writePNG(_ image: CGImage, pixels: Int, to url: URL) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: pixels * 4,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Failed to create CGContext for \(pixels)px")
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let scaled = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        fatalError("Failed to create PNG destination")
    }
    CGImageDestinationAddImage(destination, scaled, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
let sizes = [16, 32, 128, 256, 512]
var images: [[String: String]] = []
var generated = Set<Int>()
for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        if generated.insert(pixels).inserted {
            try writePNG(masterImage, pixels: pixels, to: iconsetURL.appendingPathComponent("icon-\(pixels).png"))
        }
        images.append([
            "idiom": "mac",
            "size": "\(size)x\(size)",
            "scale": "\(scale)x",
            "filename": "icon-\(pixels).png",
        ])
    }
}
let contentsData = try JSONSerialization.data(
    withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]],
    options: [.prettyPrinted, .sortedKeys]
)
try contentsData.write(to: iconsetURL.appendingPathComponent("Contents.json"))
print("Generated Cassini/AppIcon.icon and Cassini/Assets.xcassets/AppIcon.appiconset")
