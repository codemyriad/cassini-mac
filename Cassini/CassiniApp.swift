// SPDX-License-Identifier: GPL-3.0-or-later
import CassiniKit
import CassiniLibrary
import SwiftUI
import UniformTypeIdentifiers

@main
struct CassiniApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var recorder = RecordingController.shared
    @State private var captures = CaptureCollection.shared
    @AppStorage("CassiniShowMenuBar",store:RecordingPreferences.defaults) private var showIdleMenuBar = true

    var body: some Scene {
        let captureActive = recorder.isRecording || captures.isRecording
        #if DEBUG
        let suppressWindow = CommandLine.arguments.contains("--browser-return-self-test") || CommandLine.arguments.contains("--live-folder-self-test") || CommandLine.arguments.contains("--browser-background-self-test") || CommandLine.arguments.contains("--recording-saving-self-test") ||
            CommandLine.arguments.contains("--browser-capture-self-test") ||
            CommandLine.arguments.contains("--models-network-self-test") || CommandLine.arguments.contains("--parakeet-self-test") ||
            (RecordingFixture.enabled && CommandLine.arguments.contains("--fixture-windowless-launch"))
        #else
        let suppressWindow = false
        #endif
        Window(UXText.text("app.name"), id: "library") { LibraryView().tint(CassiniTheme.sceneTint) }
            .defaultLaunchBehavior(suppressWindow ? .suppressed : .presented)
            .defaultSize(width: 1120, height: 720)
            .windowToolbarStyle(.unified)
            .commands { AppCommands() }

        Settings { CassiniSettingsView().tint(CassiniTheme.sceneTint) }
            .windowResizability(.contentSize)

        MenuBarExtra(isInserted:.constant(captureActive || (captures.autoRecord && showIdleMenuBar))) {
            CassiniStatusContent().tint(CassiniTheme.sceneTint)
        } label: {
            CassiniStatusLabel()
        }
            .menuBarExtraStyle(.window)

        WindowGroup(UXText.text("app.name"), id: "legacy-viewer", for: LegacyRoute.self) { $route in
            if let route { LegacyDocumentView(url: route.url).tint(CassiniTheme.sceneTint) }
        }.defaultSize(width: 1280, height: 780)

    }
}

/// Observe capture state in the hosted views, independently of scene insertion.
private struct CassiniStatusContent: View {
    @State private var recorder=RecordingController.shared
    @State private var captures=CaptureCollection.shared
    var body: some View {
        if recorder.isRecording || captures.isRecording { RecordingStatusMenu() }
        else { IdleStatusMenu() }
    }
}
private struct CassiniStatusLabel: View {
    @State private var recorder=RecordingController.shared
    @State private var captures=CaptureCollection.shared
    var body: some View {
        if recorder.isRecording || captures.isRecording { RecordingStatusLabel() }
        else { IdleStatusLabel() }
    }
}

extension UTType {
    /// Ogg audio, which is what the system calls an `.opus` file.
    static let oggAudio = UTType(importedAs: "org.xiph.ogg-audio")
    static let opusAudio = UTType(importedAs: "org.xiph.opus")

    /// Decided audio UTIs from `contract/import-types.json` (`status == "decided"` only; excludes `flac`).
    static var decidedImportAudioContentTypes: [UTType] {
        ImportTypesContract.shared.decidedUTIIdentifiers.compactMap { identifier in
            switch identifier {
            case "org.xiph.opus": return .opusAudio
            case "org.xiph.ogg-audio": return .oggAudio
            default: return UTType(identifier)
            }
        }
    }
}

/// A read-only document: the bytes, and what the Cassini reader made of them.
struct CassiniDocument: FileDocument {
    static let readableContentTypes: [UTType] = UTType.decidedImportAudioContentTypes

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

    #if DEBUG
    init(file: CassiniFile) {
        data = Data()
        self.file = file
        readError = nil
    }
    #endif

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
