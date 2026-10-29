// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniKit
import CassiniBrowserControl

private enum CaptureChoice: String, CaseIterable {
    case me, others, both
    var title: String { UXText.text(self == .me ? "whatIsRecorded.me" : self == .others ? "common.theOthers" : "whatIsRecorded.both") }
    var caption: String { UXText.text(self == .me ? "common.yourMicrophone" : self == .others ? "whatIsRecorded.theOthers.caption" : "whatIsRecorded.both.caption") }
}
struct WhatIsRecordedView: View {
    let model: RecordingPageModel
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var permissionSide: CaptureSide?
    @State private var failedChoice: CaptureChoice?
    private var choice: CaptureChoice { model.me && model.others ? .both : model.me ? .me : .others }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            VStack(alignment:.leading,spacing:6) {
                Text(UXText.text("whatIsRecorded.title")).font(.system(size:20,weight:.bold)).accessibilityAddTraits(.isHeader)
                Text(UXText.text("whatIsRecorded.subtitle")).foregroundStyle(LibraryTheme.dim)
            }
            VStack(spacing:0) {
                ForEach(CaptureChoice.allCases,id:\.self) { item in
                    if item != .me { Divider() }
                    Button { apply(item) } label: {
                        HStack(spacing:14) {
                            ZStack {
                                Circle().stroke(item == choice ? Color.accentColor : .secondary,lineWidth:1).frame(width:17,height:17)
                                if item == choice { Circle().fill(Color.accentColor).frame(width:10,height:10) }
                            }.accessibilityHidden(true)
                            VStack(alignment:.leading,spacing:2) {
                                Text(item.title).fontWeight(.semibold)
                                Text(item.caption).font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim)
                            }
                            Spacer(minLength:0)
                        }.padding(.horizontal,16).frame(minHeight:53).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(working || (model.owned == nil && !model.frozen)).allowsHitTesting(!model.frozen)
                        .accessibilityLabel(item.title).accessibilityAddTraits(item == choice ? .isSelected : [])
                        .accessibilityIdentifier("capture-choice-" + item.rawValue)
                }
            }.background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:8))
                .overlay { RoundedRectangle(cornerRadius:8).stroke(Color.secondary.opacity(0.25)) }
                .accessibilityElement(children:.contain).accessibilityLabel(UXText.text("whatIsRecorded.choices.a11y"))
            VStack(alignment:.leading,spacing:8) {
                Text(UXText.text("whatIsRecorded.othersHeard.heading")).font(.system(size:11.5,weight:.bold)).foregroundStyle(LibraryTheme.dim)
                HStack(alignment:.top,spacing:14) {
                    Image(systemName:model.others && !model.othersUnavailable ? "checkmark" : "speaker.slash").fontWeight(.semibold).foregroundStyle(Color.accentColor).frame(width:14).padding(.top,2).accessibilityHidden(true)
                    VStack(alignment:.leading,spacing:4) {
                        Text(model.othersPathTitle).fontWeight(.bold)
                        Text(model.othersPathBody).font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
                    }
                    Spacer(minLength:0)
                }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(LibraryTheme.chip,in:RoundedRectangle(cornerRadius:8))
            }
            if let failedChoice {
                HStack(alignment:.top) {
                    Text(UXText.text("whatIsRecorded.changeFailed")).fixedSize(horizontal:false,vertical:true)
                    Spacer(minLength:8)
                    Button(UXText.text("common.tryAgain")) { apply(failedChoice) }.disabled(working)
                }.foregroundStyle(LibraryTheme.dim).accessibilityIdentifier("capture-choice-failed")
            }
            if let permissionSide { CapturePermissionNotice(side:permissionSide) }
            HStack { Spacer(); Button(UXText.text("common.done")) { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction).disabled(working) }
        }.font(.system(size:13)).padding(26).frame(width:480)
            .accessibilityElement(children:.contain).accessibilityLabel(UXText.text("whatIsRecorded.title"))
            .accessibilityIdentifier("what-is-recorded-dialog")
            .onExitCommand { if !working { dismiss() } }
    }
    private func apply(_ choice: CaptureChoice) {
        guard !working else { return }; working = true
        Task {
            defer { working = false }
            do {
                try await CaptureCollection.shared.select(model.meeting.id,me:choice != .others,others:choice != .me)
                permissionSide = nil; failedChoice = nil
            } catch {
                failedChoice = choice
                permissionSide = choice != .others && !CaptureSettings.microphoneAllowed ? .me : nil
            }
        }
    }
}
