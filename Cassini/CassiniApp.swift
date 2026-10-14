import CassiniKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct CassiniApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(viewing: CassiniDocument.self) { config in
            DocumentView(document: config.document, fileURL: config.fileURL)
        }
        .defaultSize(width: 1280, height: 780)
        .commands { AppCommands() }
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

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
