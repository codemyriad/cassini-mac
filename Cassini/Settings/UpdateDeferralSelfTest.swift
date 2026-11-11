// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import SwiftUI
import Sparkle

private struct FooterLayout: Equatable {
    let ready: Bool
    let height: CGFloat
}
private struct FooterLayoutKey: PreferenceKey {
    static let defaultValue:FooterLayout?=nil
    static func reduce(value:inout FooterLayout?,nextValue:()->FooterLayout?) {value=nextValue() ?? value}
}

/// A permanent one-point sibling keeps geometry alive when the footer is empty.
/// Read state in View.body so observation also invalidates a broken, unchanged footer.
private struct FooterLayoutProbe: View {
    let updates:ApplicationUpdates
    let report:(FooterLayout)->Void
    var body:some View {
        let ready=updates.readyWhenIdle
        return VStack(spacing:0) {
            UpdateReadyFooter(updates:updates)
            Color.clear.frame(height:1)
        }
        .fixedSize(horizontal:false,vertical:true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key:FooterLayoutKey.self,value:FooterLayout(ready:ready,height:geometry.size.height - 1))
        })
        .onPreferenceChange(FooterLayoutKey.self) { layout in
            MainActor.assumeIsolated {if let layout {report(layout)}}
        }
    }
}

/// Real updater/delegate, Sparkle status window and measured Library footer.
/// Assertions follow their signals; elapsed time is only a failure bound.
@MainActor enum UpdateDeferralSelfTest {
    private enum Failure: Error { case check(String) }
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.check(message) }
    }
    @MainActor private final class Signals {
        let context: String
        var footerLayout:FooterLayout?
        private var received=Set<String>()
        private var pending:[String:CheckedContinuation<Void,Error>]=[:]
        init(_ context:String){self.context=context}
        func send(_ name:String) {
            if let waiter=pending.removeValue(forKey:name){waiter.resume()}
            else{received.insert(name)}
        }
        func wait(_ name:String) async throws {
            if received.remove(name) != nil{return}
            try await withCheckedThrowingContinuation { continuation in
                pending[name]=continuation
                // This is a timeout, never a sleep used to assume a transition.
                DispatchQueue.main.asyncAfter(deadline:.now()+10) { [weak self] in
                    guard let self,let waiter=self.pending.removeValue(forKey:name) else{return}
                    waiter.resume(throwing:Failure.check("\(self.context): missing \(name) signal"))
                }
            }
        }
    }
    private static func installButton(_ view:NSView?) -> Bool {
        guard let view else{return false}
        if let button=view as? NSButton,button.accessibilityIdentifier()=="SUStatusInstallAndRelaunch" {return true}
        return view.subviews.contains {installButton($0)}
    }
    private static func showReady(_ controller:SPUStandardUpdaterController) throws -> NSWindow {
        typealias Reply = @convention(block) (Int) -> Void
        typealias ShowReady = @convention(c) (AnyObject,Selector,@escaping Reply) -> Void
        let selector=NSSelectorFromString("showReadyToInstallAndRelaunch:")
        let show=unsafeBitCast(controller.userDriver.method(for:selector),to:ShowReady.self)
        show(controller.userDriver,selector,{_ in})
        // Sparkle's public callback synchronously creates/shows/configures its
        // status window. Identify its real public accessible action, not an
        // arbitrary new window (or a recycled ObjectIdentifier).
        guard let window=NSApp.windows.first(where:{$0.isVisible && installButton($0.contentView)}) else {
            throw Failure.check("Sparkle ready window with Install and Relaunch was not shown")
        }
        return window
    }
    static func run() async throws {
        guard let item=SUAppcastItem(dictionary:["title":"Private update fixture","enclosure":[
            "url":"https://fixture.invalid/Cassini.zip","sparkle:version":"99","length":"100","type":"application/octet-stream"
        ]]) else {throw Failure.check("Private update item is valid")}
        for reason:ApplicationUpdates.Activity in [.recording,.saving,.scanning,.transcription] {
            let signals=Signals(String(describing:reason))
            var activity:Set<ApplicationUpdates.Activity>=[reason]
            let controller=SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:nil,userDriverDelegate:nil)
            let updates=ApplicationUpdates.fixture(controller,activity:{activity},canCheck:true)
            updates.fixtureBusyPoll={signals.send("busy poll")}
            defer {updates.finishTermination();controller.userDriver.dismissUpdateInstallation()}
            try check(updates.canCheckForUpdates,"Updater can check before deferral")
            let installationWindow=try showReady(controller)
            let closed=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:installationWindow,queue:.main) {_ in
                MainActor.assumeIsolated {signals.send("Sparkle close")}
            }
            defer {NotificationCenter.default.removeObserver(closed)}
            var resumes=0
            try check(updates.updater(controller.updater,shouldPostponeRelaunchForUpdate:item,untilInvokingBlock:{resumes += 1;signals.send("resume")}),"Protected activity postpones installation")
            try check(updates.readyWhenIdle && !updates.canCheckForUpdates,"Deferral state disables Check for Updates")
            try await signals.wait("Sparkle close")
            try check(!installationWindow.isVisible,"The real Sparkle install window closed")
            let host=NSHostingController(rootView:FooterLayoutProbe(updates:updates,report:{ layout in
                signals.footerLayout=layout
                NSLog("Update footer layout %@ ready=%d height=%g",signals.context,layout.ready ? 1:0,layout.height)
                signals.send(layout.ready ? "busy footer layout":"idle footer layout")
            }))
            let window=NSWindow(contentViewController:host)
            window.isReleasedWhenClosed=false;window.setContentSize(NSSize(width:600,height:70));window.orderFront(nil)
            defer {window.close()}
            host.view.layoutSubtreeIfNeeded()
            try await signals.wait("busy footer layout")
            try check((signals.footerLayout?.height ?? 0) > 0,"Busy activity renders the real footer")
            try await signals.wait("busy poll")
            try check(window.isVisible && resumes==0,"Visible footer and a real busy poll never resume installation")
            let waiter=updates.fixtureWaitingTask
            activity=[]
            try await signals.wait("resume")
            await waiter?.value
            // Measure real production layout after the observed updater event.
            // The preference includes model state, so a footer that incorrectly
            // stays visible delivers idle layout and fails the height assertion.
            host.view.needsLayout=true;host.view.layoutSubtreeIfNeeded()
            try await signals.wait("idle footer layout")
            try check(signals.footerLayout?.height == 0,"Idle removes the real footer from layout")
            try check(resumes==1 && !updates.readyWhenIdle && updates.fixtureWaitingTask==nil,"Idle consumes the continuation exactly once")
            updates.cancelTermination()
            try check(resumes==1 && updates.fixtureWaitingTask==nil,"Another idle evaluation cannot invoke a consumed continuation")
        }
        let signals=Signals("Quit")
        var activity:Set<ApplicationUpdates.Activity>=[.saving]
        let controller=SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:nil,userDriverDelegate:nil)
        let updates=ApplicationUpdates.fixture(controller,activity:{activity},canCheck:true)
        updates.fixtureBusyPoll={signals.send("saving poll")}
        var resumes=0
        try check(updates.updater(controller.updater,shouldPostponeRelaunchForUpdate:item,untilInvokingBlock:{resumes += 1;signals.send("resume")}),"Saving postpones before Quit")
        try await signals.wait("saving poll")
        let cancelled=updates.fixtureWaitingTask
        updates.beginTermination();activity=[]
        await cancelled?.value
        try check(resumes==0 && updates.readyWhenIdle && !updates.canCheckForUpdates,"Quit cancels the real waiter while work drains")
        updates.cancelTermination()
        let resumed=updates.fixtureWaitingTask
        try await signals.wait("resume");await resumed?.value
        try check(resumes==1 && !updates.readyWhenIdle,"Cancelled Quit resumes exactly once")
        activity=[.transcription];updates.fixtureBusyPoll={signals.send("transcription poll")}
        try check(updates.updater(controller.updater,shouldPostponeRelaunchForUpdate:item,untilInvokingBlock:{resumes += 1}),"Next installation postpones")
        try await signals.wait("transcription poll")
        let terminated=updates.fixtureWaitingTask
        updates.beginTermination();activity=[];updates.finishTermination();updates.cancelTermination()
        await terminated?.value
        try check(resumes==1 && !updates.readyWhenIdle && updates.fixtureWaitingTask==nil,"Completed Quit discards installation without relaunch")
        try check(!updates.updater(controller.updater,shouldPostponeRelaunchForUpdate:item,untilInvokingBlock:{resumes += 1}),"Idle installation proceeds normally")
        try check(resumes==1,"An unpostponed delegate never invokes its own continuation")
    }
}
#endif
