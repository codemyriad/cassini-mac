// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import Foundation
import AppKit

enum SettingsFixture {
    static var id: UUID? {
        guard ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1",
              let id = LibraryLaunchContext.argument("-CassiniSettingsID") else { return nil }
        return UUID(uuidString:id)
    }
    @MainActor private static var prepared = Set<ObjectIdentifier>()
    @MainActor static func prepare(_ window: NSWindow) {
        guard let name = LibraryLaunchContext.argument("-CassiniScreenshot"), name.hasPrefix("settings-"),
              ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1",
              prepared.insert(ObjectIdentifier(window)).inserted else { return }
        window.appearance = NSAppearance(named:.aqua)
        window.setContentSize(NSSize(width:700,height:500)); window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        guard ProcessInfo.processInfo.environment["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1" else { return }
        Task { @MainActor in
            try? await Task.sleep(for:.seconds(1))
            guard let frame = window.contentView?.superview else { exit(1) }
            let width = Int(frame.bounds.width.rounded()), height = Int(frame.bounds.height.rounded())
            guard let image = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,
                samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0) else { exit(1) }
            image.size = frame.bounds.size; frame.layoutSubtreeIfNeeded(); frame.cacheDisplay(in:frame.bounds,to:image)
            guard let png = image.representation(using:.png,properties:[:]), let output = try? JSONSerialization.data(withJSONObject:
                ["board":name,"width":width,"height":height,"pngBase64":png.base64EncodedString()]) else { exit(1) }
            FileHandle.standardOutput.write(output + Data([10])); exit(0)
        }
    }
    static var defaults: UserDefaults? { id.flatMap { UserDefaults(suiteName:"io.codemyriad.cassini.settings-fixture." + $0.uuidString) } }
}
#endif
