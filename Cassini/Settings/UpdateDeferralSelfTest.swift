// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import SwiftUI
import Sparkle

/// Exercises the real updater delegate, standard Sparkle UI and Library footer.
/// The private hosted Settings probe supplies activity; no update is downloaded
/// or installed, and the continuation only records calls.
@MainActor enum UpdateDeferralSelfTest {
    private enum Failure: Error { case check(String) }
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.check(message) }
    }
    private static func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for:.milliseconds(10)) }
        try check(condition(),"Update behavior did not settle")
    }
    private static func hasFooter(_ node: Any, depth: Int = 0) -> Bool {
        guard depth < 64, let node = node as? NSAccessibilityProtocol else { return false }
        if node.accessibilityIdentifier() == "library-update-ready" { return true }
        return (node.accessibilityChildren() ?? []).contains { hasFooter($0,depth:depth+1) }
    }
    static func run() async throws {
        guard let item = SUAppcastItem(dictionary:["title":"Private update fixture","enclosure":[
            "url":"https://fixture.invalid/Cassini.zip","sparkle:version":"99","length":"100","type":"application/octet-stream"
        ]]) else { throw Failure.check("Private update item is valid") }
        for reason: ApplicationUpdates.Activity in [.recording,.saving,.scanning,.transcription] {
            var activity: Set<ApplicationUpdates.Activity> = [reason]
            let controller = SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:nil,userDriverDelegate:nil)
            let updates = ApplicationUpdates.fixture(controller,activity:{ activity },canCheck:true)
            defer { updates.finishTermination(); controller.userDriver.dismissUpdateInstallation() }
            try check(updates.canCheckForUpdates,"Idle updater can check before deferral")
            let previous = Set(NSApp.windows.map(ObjectIdentifier.init))
            // Swift imports this public callback method as async-only. Use
            // its public Objective-C selector so dismissal may discard the
            // no-op callback without leaking a Swift async continuation.
            typealias Reply = @convention(block) (Int) -> Void
            typealias ShowReady = @convention(c) (AnyObject,Selector,Reply) -> Void
            let selector = NSSelectorFromString("showReadyToInstallAndRelaunch:")
            let show = unsafeBitCast(controller.userDriver.method(for:selector),to:ShowReady.self)
            show(controller.userDriver,selector,{ _ in })
            try await wait { NSApp.windows.contains { $0.isVisible && !previous.contains(ObjectIdentifier($0)) } }
            let installationWindows = NSApp.windows.filter { $0.isVisible && !previous.contains(ObjectIdentifier($0)) }
            var resumes = 0
            try check(updates.updater(controller.updater,shouldPostponeRelaunchForUpdate:item,untilInvokingBlock:{ resumes += 1 }),"Every protected activity postpones installation")
            try check(updates.readyWhenIdle && !updates.canCheckForUpdates,"Deferred update state disables Check for Updates")
            try await wait { installationWindows.allSatisfy { !$0.isVisible } }
            let footer = NSHostingView(rootView:UpdateReadyFooter(updates:updates))
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:70),styleMask:[.titled],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false; window.contentView = footer; window.orderFront(nil)
            defer { window.close() }
            try await wait { hasFooter(footer) }
            try await Task.sleep(for:.milliseconds(40))
            try check(resumes == 0,"A busy update never invokes the installer continuation")
            activity = []
            try await wait { resumes == 1 && !updates.readyWhenIdle }
            try await wait { !hasFooter(footer) }
            try await Task.sleep(for:.milliseconds(40))
            try check(resumes == 1,"Becoming idle resumes exactly once")
        }
        // Quit must suppress the continuation as Stop and drains become idle.
        var activity: Set<ApplicationUpdates.Activity> = [.saving]
        let controller = SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:nil,userDriverDelegate:nil)
        let updates = ApplicationUpdates.fixture(controller,activity:{ activity },canCheck:true)
        var resumes = 0
        try check(updates.updater(controller.updater,shouldPostponeRelaunchForUpdate:item,untilInvokingBlock:{ resumes += 1 }),"Saving postpones before Quit")
        updates.beginTermination(); activity = []
        try await Task.sleep(for:.milliseconds(40))
        try check(resumes == 0 && updates.readyWhenIdle && !updates.canCheckForUpdates,"Quit holds the installer while work drains")
        updates.cancelTermination()
        try await wait { resumes == 1 }
        try await Task.sleep(for:.milliseconds(40))
        try check(resumes == 1,"Cancelling Quit retains one continuation")
        activity = [.transcription]
        try check(updates.updater(controller.updater,shouldPostponeRelaunchForUpdate:item,untilInvokingBlock:{ resumes += 1 }),"Next installation postpones")
        updates.beginTermination(); activity = []; updates.finishTermination()
        updates.cancelTermination()
        try await Task.sleep(for:.milliseconds(40))
        try check(resumes == 1 && !updates.readyWhenIdle,"Completed Quit discards installation without relaunch")
        try check(!updates.updater(controller.updater,shouldPostponeRelaunchForUpdate:item,untilInvokingBlock:{ resumes += 1 }),"Idle installation proceeds normally")
        try check(resumes == 1,"An unpostponed delegate call never invokes its own continuation")
    }
}
#endif
