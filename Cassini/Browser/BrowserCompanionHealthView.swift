// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniBrowserControl

/// Render only extension-reported decisions, scoped to the exact control peer
/// and tab. Empty inventories and idle browsers never become reload warnings.
struct BrowserCompanionHealthView: View {
    let presenter: CompanionSetup.Presenter
    @State private var captures = CaptureCollection.shared
    @State private var setup = CompanionSetup.shared
    var body: some View {
        Group {
            if captures.companionHealth.reloadTabs.count > 2 {
                ScrollView { healthRows }.frame(maxHeight:220)
            } else { healthRows }
        }.font(.system(size:11.5))
    }
    private var healthRows: some View {
        VStack(alignment:.leading,spacing:10) {
            ForEach(captures.companionHealth.peers,id: \.id) { peer in peerStatus(peer) }
        }
    }
    private func peerStatus(_ peer: BrowserControlPeerSnapshot) -> some View {
        let outdated = CompanionSetup.bundledCompanionVersion.map { peer.diagnostics.isOlder(than:$0) } ?? false
        let repairs = peer.browserHealth?.reloadTabs ?? []
        let setupAgain = peer.diagnostics.filesOk != true || outdated || !peer.supportsMultiStream
        return VStack(alignment:.leading,spacing:6) {
            if setupAgain || !repairs.isEmpty {
                if let name = peer.browser { Text(name).fontWeight(.semibold) }
            }
            if peer.diagnostics.filesOk == false {
                Text(UXText.text("setup.companion.filesMissing")).fixedSize(horizontal:false,vertical:true)
                    .accessibilityIdentifier("companion-files-missing")
            }
            if outdated, let version = peer.diagnostics.extensionVersion {
                Text(UXText.text("setup.companion.outdated",["version":version])).fixedSize(horizontal:false,vertical:true)
                    .accessibilityIdentifier("companion-outdated")
            }
            if setupAgain {
                Button(UXText.text("setup.companion.setUpAgain")) { setup.showLocalGuide(from:presenter) }
                    .disabled(!setup.canAdd || setup.working).accessibilityIdentifier("companion-setup-again")
            }
            ForEach(repairs,id: \.key) { tab in
                reloadRow(tab,peer:peer)
            }
        }
    }
    private func reloadRow(_ tab: BrowserTabHealth, peer: BrowserControlPeerSnapshot) -> some View {
        VStack(alignment:.leading,spacing:5) {
            if let meeting = peer.meetings.first(where:{ $0.key == tab.key }) { Text(meeting.title).fontWeight(.semibold) }
            HStack(alignment:.firstTextBaseline,spacing:12) {
                Text(UXText.text("setup.companion.reloadTab")).fixedSize(horizontal:false,vertical:true)
                    .accessibilityIdentifier("companion-reload-message")
                Button(UXText.text("setup.companion.reloadTab.action")) { captures.reloadMeetingTab(tab.key) }
                    .disabled(!tab.canReload || !peer.supportsTabReadiness || captures.reloadingTabs.contains(tab.key) || peer.captures.contains(where:{ $0.key == tab.key }))
                    .accessibilityIdentifier("companion-reload-tab-\(peer.id)-\(tab.key.tabID)")
            }
            if let error = captures.reloadErrors[tab.key] {
                Text(error).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    .accessibilityIdentifier("companion-reload-error")
            }
        }
    }
}
