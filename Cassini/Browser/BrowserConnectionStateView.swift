// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Shared, quiet connection state for Settings and the Library.
struct BrowserConnectionStateView: View {
    let identifier: String
    var presenter: CompanionSetup.Presenter = .settings
    @State private var setup = CompanionSetup.shared
    @State private var captures = CaptureCollection.shared
    var body: some View {
        HStack(alignment:.firstTextBaseline,spacing:12) {
            Text(setup.stateLine).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier(identifier)
            Spacer(minLength:8)
            if !captures.connected {
                if setup.failed {
                    Button(UXText.text("common.tryAgain")) { setup.trigger() }.accessibilityIdentifier("browser-try-again")
                } else if !setup.working || setup.noBrowser {
                    Button(setup.addLabel) { setup.add(from:presenter) }.accessibilityIdentifier("browser-add")
                        .disabled(!setup.canAdd)
                }
            }
        }
    }
}
