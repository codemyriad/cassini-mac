// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import CassiniLibrary

/// Production model/routing with synthetic turns, no transport or audio devices.
@MainActor enum ListeningSelfTest {
    static func run() async {
        let timeout = Task { @MainActor in
            try? await Task.sleep(for:.seconds(15))
            if !Task.isCancelled { exit(3) }
        }
        guard var meeting = try? LibraryScanner(root:LibraryStore.shared.context.root).scan().meetings.first(where:{ $0.state.lifecycle == .saved && !$0.speakers.isEmpty }) else {
            FileHandle.standardError.write(Data("No saved speaker fixture\n".utf8)); exit(2)
        }
        guard let template = meeting.speakers.first else { exit(2) }
        var a = template, b = template
        a.id = "a"; b.id = "b"; a.name = "Unidentified voice"; b.name = "Unidentified voice"
        meeting.speakers = [a,b]
        meeting.transcriptItems = [
            .init(speaker:"a",startMs:62000,endMs:63000,text:"First."),
            .init(speaker:"b",startMs:798000,endMs:799000,text:"Aside."),
            .init(speaker:"a",startMs:1518000,endMs:1519000,text:"Later.")]
        let detail = MeetingDetailModel(meeting:meeting,frozen:true)
        MeetingNavigation.shared.detail = detail
        detail.listen.preview("a")
        let window = NSWindow(contentRect:.init(x:0,y:0,width:400,height:200),styleMask:[.titled],backing:.buffered,defer:false)
        window.setAccessibilityIdentifier("cassini-library-window")
        let host = NSView(frame:window.contentLayoutRect)
        let editor = NSTextView(frame:.init(x:0,y:0,width:100,height:30))
        host.addSubview(editor); window.contentView = host
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
        var messages: [String] = []
        MeetingDetailModel.announcementForSelfTest = { messages.append($0) }
        var report: [String:Bool] = [:]
        detail.resetListeningAnnouncement(); detail.announceListeningTurn()
        report["speakerOnStartWithEditor"] = messages.last == detail.listeningPresentation?.speakerAnnouncement && messages.last?.contains("00:01:02") == true
        report["editorBlocksShortcutOnly"] = !detail.canUseListeningShortcuts(in:window) && detail.canUseListeningCommands
        detail.stepListeningTurn(1); detail.announceListeningTurn()
        report["turnWithEditor"] = messages.last == "Turn 2 of 2, 00:25:18"
        // IDs rather than display names distinguish two unnamed speakers.
        detail.listen.preview("b"); detail.announceListeningTurn()
        report["speakerChangeWithEditor"] = messages.last == detail.listeningPresentation?.speakerAnnouncement && messages.last?.contains("00:13:18") == true
        detail.stopListening(); detail.listen.preview("b"); detail.announceListeningTurn()
        report["restartSameSpeaker"] = messages.last == detail.listeningPresentation?.speakerAnnouncement
        let count = messages.count
        MeetingNavigation.shared.detail = nil; detail.announceListeningTurn()
        report["inactivePageSilent"] = messages.count == count
        MeetingNavigation.shared.detail = detail
        detail.stopListening(); detail.announceListeningTurn()
        report["stoppedSilent"] = messages.count == count
        detail.listen.preview("a")
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [.option,.command]) -> NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
        }
        report["editorKeyPassedThrough"] = AppDelegate.handleListeningSelfTest(key(125)) != nil && detail.listen.index == 0
        window.makeFirstResponder(host)
        let sheet = NSWindow(contentRect:.init(x:0,y:0,width:200,height:100),styleMask:[.titled],backing:.buffered,defer:false)
        let (ended,emit) = AsyncStream<Void>.makeStream()
        let observer = NotificationCenter.default.addObserver(forName:NSWindow.didEndSheetNotification,object:window,queue:.main) { _ in emit.yield(()) }
        window.beginSheet(sheet,completionHandler:{ _ in })
        report["sheetKeyPassedThrough"] = AppDelegate.handleListeningSelfTest(key(125)) != nil
        window.endSheet(sheet)
        var next = ended.makeAsyncIterator(); _ = await next.next()
        NotificationCenter.default.removeObserver(observer); emit.finish()
        sheet.orderOut(nil); window.makeFirstResponder(host)
        report["turnDownAfterSheet"] = AppDelegate.handleListeningSelfTest(key(125)) == nil && detail.listen.index == 1
        report["turnUpAfterSheet"] = AppDelegate.handleListeningSelfTest(key(126)) == nil && detail.listen.index == 0
        report["speakerDownAfterSheet"] = AppDelegate.handleListeningSelfTest(key(125,[.option,.command,.shift])) == nil && detail.listen.speaker == "b"
        report["speakerUpAfterSheet"] = AppDelegate.handleListeningSelfTest(key(126,[.option,.command,.shift])) == nil && detail.listen.speaker == "a"
        window.makeFirstResponder(editor)
        report["commandsIgnoreEditorFocus"] = detail.canUseListeningCommands && !detail.canUseListeningShortcuts(in:window)
        window.makeFirstResponder(host)
        report["turnAfterLeavingEditor"] = AppDelegate.handleListeningSelfTest(key(125)) == nil && detail.listen.index == 1
        report["turnUpAfterLeavingEditor"] = AppDelegate.handleListeningSelfTest(key(126)) == nil && detail.listen.index == 0
        report["speakerDownAfterLeavingEditor"] = AppDelegate.handleListeningSelfTest(key(125,[.option,.command,.shift])) == nil && detail.listen.speaker == "b"
        report["speakerUpAfterLeavingEditor"] = AppDelegate.handleListeningSelfTest(key(126,[.option,.command,.shift])) == nil && detail.listen.speaker == "a"
        report["otherModifiersPassedThrough"] = AppDelegate.handleListeningSelfTest(key(125,[.option,.command,.control])) != nil && detail.listen.index == 0
        let menu = NSMenu(title:"Listening scope")
        NotificationCenter.default.post(name:NSMenu.didBeginTrackingNotification,object:menu)
        report["menuKeepsKeys"] = AppDelegate.handleListeningSelfTest(key(125)) != nil && detail.listen.index == 0
        NotificationCenter.default.post(name:NSMenu.didEndTrackingNotification,object:menu)
        detail.close(); MeetingNavigation.shared.detail = nil
        MeetingDetailModel.announcementForSelfTest = nil; timeout.cancel()
        FileHandle.standardOutput.write((try! JSONSerialization.data(withJSONObject:report,options:[.sortedKeys])) + Data([10])); exit(0)
    }
}
#endif
