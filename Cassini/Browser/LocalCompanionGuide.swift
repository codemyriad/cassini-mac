// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct LocalCompanionGuide: View {
    @State private var setup = CompanionSetup.shared
    @State private var captures = CaptureCollection.shared
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text(UXText.text("companion.local.title")).font(.system(size:20,weight:.bold)).accessibilityAddTraits(.isHeader)
            Menu(setup.selectedBrowserName) {
                ForEach(setup.installedBrowsers,id:\.bundleID) { browser in
                    Button(browser.name) { setup.selectBrowser(browser) }
                }
            }.fixedSize().accessibilityIdentifier("companion-browser-choice")
            VStack(alignment:.leading,spacing:18) {
                instruction(1,"companion.local.step1") {
                    Button(UXText.text("companion.local.copyExtensions",["browser":setup.selectedBrowserName])) { setup.copyAddressAndOpen() }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("companion-copy-address")
                    Text(UXText.text("companion.local.extensionsPasteHint")).font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim)
                    if setup.launchFailed {
                        failure("companion.local.openFailed") { setup.copyAddressAndOpen() }
                    }
                }
                Divider()
                instruction(2,"companion.local.step2") { EmptyView() }
                Divider()
                instruction(3,"companion.local.step3") {
                    Button(UXText.text("companion.local.copyFolder")) { setup.copyFolder() }
                        .disabled(!setup.prepared).accessibilityIdentifier("companion-copy-folder")
                    Text(UXText.text("companion.local.pasteHint")).font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim)
                    if setup.preparationFailed {
                        failure("companion.local.prepareFailed") { setup.localBackground.trigger() }
                    } else if !setup.prepared { ProgressView().controlSize(.small) }
                }
            }.padding(18).background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:8))
                .overlay { RoundedRectangle(cornerRadius:8).stroke(Color.secondary.opacity(0.25)) }
            Text(UXText.text("companion.local.devModeNote",["browser":setup.selectedBrowserName]))
                .font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim).fixedSize(horizontal:false,vertical:true)
            HStack(alignment:.firstTextBaseline,spacing:12) {
                Text(setup.stateLine).foregroundStyle(LibraryTheme.dim).accessibilityIdentifier("companion-local-status")
                if setup.failed { Button(UXText.text("common.tryAgain")) { setup.trigger() } }
            }
            HStack {
                Spacer()
                Button(UXText.text("common.notNow")) { setup.close() }.keyboardShortcut(.cancelAction)
                Button(UXText.text("common.done")) { setup.close() }.keyboardShortcut(.defaultAction)
                    .disabled(!captures.connected).accessibilityIdentifier("companion-local-done")
            }.controlSize(.large)
        }.font(.system(size:13)).padding(26).frame(width:560)
            .accessibilityElement(children:.contain).accessibilityIdentifier("companion-local-guide")
            .overlay(alignment:.bottomLeading) {
                if let copied = setup.copiedNotice {
                    Text(copied).font(.system(size:11.5,weight:.medium)).padding(.horizontal,12).padding(.vertical,8)
                        .background(.regularMaterial,in:Capsule()).shadow(radius:2).padding(.leading,26).padding(.bottom,24)
                        .accessibilityIdentifier("companion-copied")
                }
            }
            .task(id:setup.copyRevision) {
                do { try await Task.sleep(for:.seconds(3)); setup.copiedNotice = nil } catch { }
            }
    }
    private func instruction<Content:View>(_ number: Int, _ key: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment:.top,spacing:12) {
            Text(String(number)).fontWeight(.bold).foregroundStyle(Color.accentColor).frame(width:24,height:24)
                .overlay(Circle().stroke(Color.accentColor,lineWidth:1.5))
            VStack(alignment:.leading,spacing:8) {
                Text(UXText.text(key,["browser":setup.selectedBrowserName])).fontWeight(.semibold).fixedSize(horizontal:false,vertical:true)
                content()
            }
        }
    }
    private func failure(_ key: String, retry: @escaping () -> Void) -> some View {
        HStack(alignment:.firstTextBaseline,spacing:10) {
            Text(UXText.text(key,["browser":setup.selectedBrowserName])).foregroundStyle(LibraryTheme.amber).fixedSize(horizontal:false,vertical:true)
            Button(UXText.text("common.tryAgain"),action:retry)
        }
    }
}
