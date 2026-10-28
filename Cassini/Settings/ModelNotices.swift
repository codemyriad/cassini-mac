// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniModels

/// Keep the native localized About menu/panel. Document links use their actual
/// filenames; no new prose or model rows are invented outside the catalog.
@MainActor enum ModelNotices {
    static func configureMenu() {
        guard let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where:{ $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)) }) else { return }
        item.target = Action.shared; item.action = #selector(Action.show(_:))
    }
    static var files: [URL] {
        let paths = [("Zstandard-LICENSE","txt","Licenses"),
                     ("NOTICE",nil,"Whistle"),("LICENSE",nil,"Whistle"),("Silero-LICENSE",nil,"Whistle"),
                     ("ONNXRuntime-LICENSE",nil,"Whistle"),("ONNXRuntime-ThirdPartyNotices","txt","Whistle")]
        return paths.compactMap { Bundle.main.url(forResource:$0.0,withExtension:$0.1,subdirectory:$0.2) }

    }
    static var credits: NSAttributedString { credits(appData:ModelStorage.appData) }
    static func credits(appData: URL) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for file in files {
            let name = file.path.contains("/models/") ? file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent + "/NOTICE.txt" : file.pathComponents.suffix(2).joined(separator:"/")
            text.append(NSAttributedString(string:name,attributes:[.link:file,.font:NSFont.systemFont(ofSize:12)]))
            text.append(NSAttributedString(string:"\n"))
        }
        // Each installed revision carries dist's full NOTICE. The download
        // link is conditional; bundled Whistle is not a downloaded model.
        let notices = ModelStorage.notices(in:appData)
        if let notice = notices.max(by:{
            ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
            ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }) {
            text.append(NSAttributedString(string:UXText.text("about.modelNotices"),attributes:[.link:notice,.font:NSFont.systemFont(ofSize:12)]))
            text.append(NSAttributedString(string:"\n"))
        }
        return text
    }
    @MainActor private final class Action: NSObject {
        static let shared = Action()
        @objc func show(_ sender: Any?) { NSApp.orderFrontStandardAboutPanel(options:[.credits:ModelNotices.credits]) }
    }
    #if DEBUG
    static var menuConfigured: Bool {
        NSApp.mainMenu?.items.first?.submenu?.items.contains { $0.action == #selector(Action.show(_:)) } == true
    }
    #endif
}
