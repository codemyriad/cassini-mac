// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit

@MainActor enum AboutPanel {
    static let helpURL = URL(string:"https://cassini.talk/help")!
    static let reportProblemURL = URL(string:"https://cassini.talk/report")!
    static let privacyURL = URL(string:"https://cassini.talk/privacy")!
    static let sourceCodeURL = URL(string:"https://github.com/codemyriad/cassini-mac")!
    static var version: String { Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "" }
    static var copyrightYear: String { String((Bundle.main.object(forInfoDictionaryKey:"NSHumanReadableCopyright") as? String ?? "").filter(\.isNumber).prefix(4)) }
    private static var panel: NSPanel?
    static func show() {
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:300,height:350),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        panel.title = UXText.text("app.name")
        panel.setAccessibilityIdentifier("cassini-about-window")
        panel.contentView = NSHostingView(rootView:AboutView())
        panel.isReleasedWhenClosed = false
        self.panel = panel
        panel.center(); panel.makeKeyAndOrderFront(nil)
        #if DEBUG
        SettingsFixture.prepare(panel)
        #endif
    }
}
struct AboutView: View {
    @State private var licences = false
    var body: some View {
        VStack(spacing:14) {
            if let mark = CassiniBrandMark.image(forHeight:64) { Image(nsImage:mark).resizable().scaledToFit().frame(height:64).accessibilityHidden(true) }
            Text(UXText.text("app.name")).font(.title2).fontWeight(.bold)
            Text(UXText.text("about.version",["version":AboutPanel.version])).font(.caption).foregroundStyle(CassiniTheme.ink2)
            Text(UXText.text("about.tagline.mac")).multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)
            VStack(spacing:6) {
                HStack(spacing:7) {
                    Link(UXText.text("about.help"),destination:AboutPanel.helpURL).accessibilityIdentifier("about-help")
                    Text("·").accessibilityHidden(true)
                    Link(UXText.text("about.reportProblem"),destination:AboutPanel.reportProblemURL).accessibilityIdentifier("about-report-problem")
                    Text("·").accessibilityHidden(true)
                    Link(UXText.text("about.privacy"),destination:AboutPanel.privacyURL).accessibilityIdentifier("about-privacy")
                }
                HStack(spacing:7) {
                    Button(UXText.text("about.licences")) { licences = true }.buttonStyle(.link).accessibilityIdentifier("about-licences")
                    Text("·").accessibilityHidden(true)
                    Link(UXText.text("about.sourceCode"),destination:AboutPanel.sourceCodeURL).accessibilityIdentifier("about-source-code")
                }
            }.font(.system(size:11.5))
            Text(UXText.text("about.licenceLine.mac",["year":AboutPanel.copyrightYear])).font(.system(size:10)).foregroundStyle(CassiniTheme.ink2)
                .multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)
        }.padding(22).frame(width:300).background(CassiniTheme.windowGround)
            .sheet(isPresented:$licences) { LicencesView() }
    }
}
private struct LicencesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var credits = AttributedString()
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text(UXText.text("about.licences")).font(.headline)
            ScrollView { Text(credits).frame(maxWidth:.infinity,alignment:.leading) }
            HStack { Spacer(); Button(UXText.text("common.close")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width:420,height:340)
            .task {
                let appData = SpeechModelController.appData
                credits = await Task.detached(priority:.utility) {
                    AttributedString(ModelNotices.credits(appData:appData))
                }.value
            }
    }
}
