// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Shared, quiet connection state for Settings and the Library.
struct BrowserConnectionStateView: View {
    let identifier: String
    var phase2 = false
    var presenter: CompanionSetup.Presenter = .settings
    @State private var setup = CompanionSetup.shared
    @State private var captures = CaptureCollection.shared
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(alignment:.firstTextBaseline,spacing:12) {
                Text(setup.stateLine).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier(identifier)
                Spacer(minLength:8)
                if !captures.connected || phase2 {
                    if setup.failed && !captures.connected {
                        Button(UXText.text("common.tryAgain")) { setup.trigger() }.accessibilityIdentifier("browser-try-again")
                    } else if !setup.working || setup.noBrowser {
                        Button(phase2 && !setup.selectedBrowserName.isEmpty ? UXText.text("companion.addTo",["browser":setup.selectedBrowserName]) : setup.addLabel) {
                            if captures.connected { setup.showLocalGuide(from:presenter) }
                            else { setup.add(from:presenter) }
                        }.accessibilityIdentifier(captures.connected && phase2 ? "settings-add-local-companion" : "browser-add")
                            .disabled(!setup.canAdd)
                    }
                }
            }
            BrowserCompanionHealthView(presenter:presenter)
        }
    }
}
