// SPDX-License-Identifier: GPL-3.0-or-later
import CassiniKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct CassiniApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var recorder = RecordingController.shared

    var body: some Scene {
        let captureActive = recorder.isRecording
        #if DEBUG
        let suppressWindow = CommandLine.arguments.contains("--recording-saving-self-test") ||
            CommandLine.arguments.contains("--models-network-self-test") || CommandLine.arguments.contains("--parakeet-self-test")
        #else
        let suppressWindow = false
        #endif
        Window(UXText.text("library.title"), id: "library") { LibraryView() }
            .defaultLaunchBehavior(suppressWindow ? .suppressed : .presented)
            .defaultSize(width: 1120, height: 720)
            .windowToolbarStyle(.unified)
            .commands { AppCommands() }

        Settings { CassiniSettingsView() }
            .windowResizability(.contentSize)

        MenuBarExtra(isInserted:.constant(captureActive)) { RecordingStatusMenu() } label: { RecordingStatusLabel() }
            .menuBarExtraStyle(.window)

        WindowGroup(UXText.text("library.title"), id: "legacy-viewer", for: LegacyRoute.self) { $route in
            if let route { LegacyDocumentView(url: route.url) }
        }.defaultSize(width: 1280, height: 780)

    }
}

extension UTType {
    /// Ogg audio, which is what the system calls an `.opus` file.
    static let oggAudio = UTType(importedAs: "org.xiph.ogg-audio")
}

/// A read-only document: the bytes, and what the Cassini reader made of them.
struct CassiniDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.oggAudio]

    let data: Data
    let file: CassiniFile?
    let readError: String?

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        do {
            file = try CassiniReader.read(data)
            readError = nil
        } catch {
            file = nil
            readError = "\(error)"
        }
    }

    init(url: URL) throws {
        data = try Data(contentsOf: url)
        do { file = try CassiniReader.read(data); readError = nil }
        catch { file = nil; readError = "\(error)" }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
