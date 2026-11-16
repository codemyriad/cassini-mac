// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import Foundation
import AppKit
import Observation

@MainActor @Observable final class SettingsRenderReadiness {
    static let shared = SettingsRenderReadiness()
    var transcription = false
    var libraryRevision: Int?
}

enum SettingsFixture {
    static var id: UUID? {
        guard ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1",
              let id = LibraryLaunchContext.argument("-CassiniSettingsID") else { return nil }
        return UUID(uuidString:id)
    }
    @MainActor static var speechMemory: UInt64? {
        guard id != nil, let value = LibraryLaunchContext.argument("-CassiniSpeechMemoryBytes") else { return nil }
        return UInt64(value)
    }
    @MainActor private static var prepared = Set<ObjectIdentifier>()
    @MainActor static func prepare(_ window: NSWindow) {
        guard let name = LibraryLaunchContext.argument("-CassiniScreenshot"), (name.hasPrefix("settings-") || name == "about"),
              ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1",
              prepared.insert(ObjectIdentifier(window)).inserted else { return }
        window.appearance = NSAppearance(named:LibraryLaunchContext.screenshotDark ? .darkAqua : .aqua)
        window.setContentSize(name == "about" ? NSSize(width:300,height:330) : NSSize(width:700,height:560)); window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        guard ProcessInfo.processInfo.environment["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1" else { return }
        Task { @MainActor in
            @MainActor func ready() -> Bool {
                if name == "settings-transcription" { return SettingsRenderReadiness.shared.transcription }
                if name == "settings-library" { return LibraryStore.shared.loaded && SettingsRenderReadiness.shared.libraryRevision == LibraryStore.shared.revision }
                return true
            }
            while !ready() {
                let (events, signal) = AsyncStream<Void>.makeStream()
                withObservationTracking { _ = ready() } onChange: { signal.yield(); signal.finish() }
                var iterator = events.makeAsyncIterator(); _ = await iterator.next()
            }
            // Render after the queued SwiftUI layout transaction, never a time delay.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
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
