// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

/// D78: both surfaces share the explicit Download action and persisted dismissal.
struct ParakeetRecommendationView: View {
    @State private var models = SpeechModelController.shared
    let afterFirst: Bool
    @State private var afterFirstVisible = false
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
        if models.showsSettingsSuggestion && (!afterFirst || afterFirstVisible) {
            HStack(alignment:.top,spacing:14) {
                VStack(alignment:.leading,spacing:5) {
                    Text(UXText.text("models.parakeetSuggestion.title")).font(.system(size:12,weight:.semibold))
                    Text(UXText.text("models.parakeetSuggestion.body",["size":LibraryFormat.size(bytes:SpeechModelController.downloadBytes)]))
                        .font(.system(size:12)).foregroundStyle(LibraryTheme.dim).fixedSize(horizontal:false,vertical:true)
                }
                Spacer(minLength:0)
                VStack(alignment:.trailing,spacing:6) {
                    Button(UXText.text("models.parakeetSuggestion.download")) { models.download() }
                        .accessibilityIdentifier(afterFirst ? "library-parakeet-download" : "settings-parakeet-suggestion-download")
                    Button(UXText.text("common.notNow")) { models.dismissSuggestion() }
                        .buttonStyle(.link).accessibilityIdentifier(afterFirst ? "library-parakeet-not-now" : "settings-parakeet-not-now")
                }
            }.padding(14).background(LibraryTheme.chip,in:RoundedRectangle(cornerRadius:8))
                .accessibilityElement(children:.contain)
                .accessibilityIdentifier(afterFirst ? "library-parakeet-suggestion" : "settings-parakeet-suggestion")
        }
        }
        .onAppear { claim() }
        .onChange(of:models.showsAfterFirstSuggestion) { _, available in if available { claim() } }
        .onDisappear { afterFirstVisible = false }
    }
    private func claim() {
        if afterFirst, models.takeAfterFirstSuggestion() { afterFirstVisible = true }
    }
}

/// The first mounted surface claims the persisted notice. Its local visibility
/// lasts until leaving that surface or choosing Whistle; relaunch cannot repeat it.
struct ParakeetDefaultNotice: View {
    @State private var models = SpeechModelController.shared
    @State private var visible = false
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            if visible {
                Text(UXText.text("models.parakeetUltra.nowDefault"))
                    .font(.system(size:12)).foregroundStyle(LibraryTheme.dim)
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .padding(.vertical,8).accessibilityIdentifier("parakeet-now-default")
            }
        }
        .onAppear { claim() }
        .onChange(of:models.canAnnounceDefault) { _, available in if available { claim() } }
        .onChange(of:models.usesParakeet) { _, selected in if !selected { visible = false } }
        .onDisappear { visible = false }
    }
    private func claim() { if models.takeDefaultAnnouncement() { visible = true } }
}
