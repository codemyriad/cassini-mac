// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// Saturn brand mark (`L-04`) and lowercase `cassini.talk` wordmark lockup (`L-15`).
/// Selects `mark-flat.svg` below 20 pt, `saturn-nav.svg` up to 40 pt, and `saturn-mid.svg` above 40 pt.
struct CassiniBrandMark: View {
    var height: CGFloat = 26

    static func assetName(forHeight height: CGFloat) -> String {
        if height < 20 { return "mark-flat" }
        if height <= 40 { return "saturn-nav" }
        return "saturn-mid"
    }

    private static var cache: [String: NSImage] {
        var loaded: [String: NSImage] = [:]
        for name in ["mark-flat", "saturn-nav", "saturn-mid", "saturn-full"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "Brand"),
               let image = NSImage(contentsOf: url) {
                loaded[name] = image
            }
        }
        return loaded
    }

    private static let images = cache

    var body: some View {
        let width = round(height * 184.0 / 120.0)
        if let image = Self.images[Self.assetName(forHeight: height)] {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: width, height: height)
                .accessibilityHidden(true)
        }
    }
}

/// In-app wordmark lockup (`L-15`): 26 pt Saturn mark paired with lowercase `"cassini.talk"` at 18 pt medium weight.
struct CassiniBrandLockup: View {
    static let wordmarkText = "cassini.talk"

    var body: some View {
        HStack(spacing: 10) {
            CassiniBrandMark(height: 26)
            Text(Self.wordmarkText)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(CassiniTheme.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UXText.text("app.name"))
    }
}
