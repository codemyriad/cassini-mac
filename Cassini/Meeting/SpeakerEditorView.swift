// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

/// WP6: a single column dialog. Voice profiles are not yet prepared on Mac;
/// naming stays available without pretending that a voiceprint has been saved.
struct SpeakerEditorView:View {
    @State private var edit=MeetingRenameCoordinator.shared
    private enum Control:Hashable {case sample,name,merge,retry,cancel,save}
    @FocusState private var focused:Control?
    private var detail:MeetingDetailModel? {MeetingNavigation.shared.detail}
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            if let meeting=edit.meeting,let speaker=edit.selectedSpeaker {
                header(speaker)
                if let quote=edit.speakerQuote {excerpt(quote)}
                nameEntry
                savedVoices
                rememberVoice
                if edit.speakerChangeFailed {failure}
                footer(meeting,speaker)
            }
        }.font(.system(size:13)).foregroundStyle(CassiniTheme.ink)
            .padding(24).frame(width:470)
            .background(CassiniTheme.raised,in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(CassiniTheme.lineSoft,lineWidth:1))
            .shadow(color:CassiniTheme.shadow,radius:24,y:12)
            .accessibilityElement(children:.contain).accessibilityLabel(UXText.text("speakers.dialog.a11y"))
            .accessibilityAddTraits(.isModal).accessibilityIdentifier("speaker-editor")
            .background(SpeakerDialogKeyboard(advance:advanceFocus))
            .onAppear {focused = .name}
            .onDisappear {detail?.speakerSample.cancel()}
    }
    private func header(_ speaker:MeetingSpeaker)->some View {
        HStack(spacing:12) {
            VStack(alignment:.leading,spacing:4) {
                Text(speaker.displayName).font(.system(size:18,weight:.semibold))
                    .foregroundStyle(CassiniTheme.ink).lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if edit.speakerPreparing {ProgressView().controlSize(.small)}
                else {
                    Text(UXText.text("speakers.talkTime",["talkTime":LibraryFormat.talkTime(edit.speakerTalkTime,locale:UXText.locale,language:UXText.language)]))
                        .foregroundStyle(CassiniTheme.ink2)
                }
            }
            Spacer()
            sampleButton
        }
    }
    private var sampleButton:some View {
        Button {
            guard let detail else {return}
            if detail.speakerSample.active {detail.speakerSample.cancel()}
            else if let range=edit.speakerSampleRange {detail.playSpeakerSample(range)}
        } label: {
            Image(systemName:detail?.speakerSample.active == true ? "stop.fill" : "play.fill")
                .frame(width:30,height:30)
        }.buttonStyle(.plain)
            .background(CassiniTheme.neutralPillFill,in:Circle())
            .accessibilityLabel(UXText.text(detail?.speakerSample.active == true ? "common.stop" : "speakers.playSample"))
            .disabled(edit.working || detail?.canPlay != true || edit.speakerSampleRange==nil)
            .focusable().focused($focused,equals:.sample)
            .accessibilityIdentifier("speaker-play-sample")
    }
    private func excerpt(_ quote:String)->some View {
        HStack(spacing:12) {
            RoundedRectangle(cornerRadius:2).fill(CassiniTokens.line).frame(width:3)
            Text(UXText.text("common.quote",["quote":quote])).foregroundStyle(CassiniTheme.ink2).lineLimit(3)
                .frame(maxWidth:.infinity,alignment:.leading)
        }.fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("speaker-quote")
    }
    private var nameEntry:some View {
        VStack(alignment:.leading,spacing:7) {
            Text(UXText.text("speakers.nameLabel")).fontWeight(.semibold).foregroundStyle(CassiniTheme.ink)
            TextField("", text:$edit.name)
                .textFieldStyle(.plain).padding(10)
                .background(CassiniTheme.field,in:RoundedRectangle(cornerRadius:6))
                .overlay(RoundedRectangle(cornerRadius:6).stroke(focused == .name ? CassiniTheme.accent : CassiniTheme.fieldLine,lineWidth:1))
                .focused($focused,equals:.name).disabled(edit.working)
                .accessibilityLabel(UXText.text("speakers.nameLabel"))
                .accessibilityIdentifier("speaker-name-field")
                .onSubmit {if edit.canApply {edit.apply()}}
        }
    }
    private var savedVoices:some View {
        VStack(alignment:.leading,spacing:8) {
            Text(UXText.text("common.savedVoices")).fontWeight(.semibold)
            Text(UXText.text("savedVoices.empty")).foregroundStyle(CassiniTheme.ink2)
                .frame(maxWidth:.infinity,alignment:.leading).padding(12)
                .background(CassiniTheme.surface,in:RoundedRectangle(cornerRadius:12))
                .overlay(RoundedRectangle(cornerRadius:12).stroke(CassiniTheme.lineSoft,lineWidth:1))
        }
    }
    private var rememberVoice:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(alignment:.top,spacing:12) {
                VStack(alignment:.leading,spacing:5) {
                    Text(UXText.text("speakers.rememberVoice.title"))
                    Text(UXText.text("speakers.rememberVoice.notPrepared"))
                        .accessibilityIdentifier("speaker-remember-explanation")
                        .font(.system(size:12)).foregroundStyle(CassiniTheme.ink2)
                        .fixedSize(horizontal:false,vertical:true)
                }
                Spacer(minLength:0)
                Toggle(UXText.text("speakers.rememberVoice.title"),isOn:.constant(false))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(true)
                    .accessibilityIdentifier("speaker-remember-voice")
            }
        }.padding(14).background(CassiniTheme.surface,in:RoundedRectangle(cornerRadius:12))
                .overlay(RoundedRectangle(cornerRadius:12).stroke(CassiniTheme.lineSoft,lineWidth:1))
    }
    private var failure:some View {
        HStack(spacing:10) {
            Text(UXText.text("speakers.changeFailed")).foregroundStyle(CassiniTheme.error)
                .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("speaker-change-error")
            Button(UXText.text("common.tryAgain")) {edit.retrySpeakerEdit()}.disabled(!edit.canRetrySpeakerEdit).focusable().focused($focused,equals:.retry)
        }.padding(12).background(CassiniTheme.errorTint,in:RoundedRectangle(cornerRadius:7))
    }
    private func footer(_ meeting:LibraryMeeting,_ speaker:MeetingSpeaker)->some View {
        HStack {
            Menu(UXText.text("speakers.mergeInto")) {
                ForEach(meeting.speakers.filter {$0.id != speaker.id},id:\.id) {other in
                    Button(other.displayName) {edit.mergeSpeaker(into:other.id)}
                        .accessibilityIdentifier("speaker-merge-into-"+other.id)
                }
            }.fixedSize().disabled(edit.working || meeting.speakers.count<2)
                .focusable().focused($focused,equals:.merge)
                .accessibilityIdentifier("speaker-merge-menu")
            Spacer(minLength:0)
            if edit.working {ProgressView().controlSize(.small)}
            Button(UXText.text("common.cancel")) {edit.cancel()}
                .keyboardShortcut(.cancelAction).disabled(edit.working)
                .focusable().focused($focused,equals:.cancel)
                .accessibilityIdentifier("speaker-cancel")
            Button(UXText.text("speakers.saveName")) {edit.apply()}
                .keyboardShortcut(.defaultAction).disabled(!edit.canApply)
                .focusable().focused($focused,equals:.save)
                .accessibilityIdentifier("speaker-save-name")
        }
    }
    private func advanceFocus(_ reverse:Bool) {
        var controls:[Control]=[]
        if !edit.working && detail?.canPlay == true && edit.speakerSampleRange != nil {controls.append(.sample)}
        if !edit.working {controls.append(.name)}
        if !edit.working && (edit.meeting?.speakers.count ?? 0)>1 {controls.append(.merge)}
        if edit.speakerChangeFailed && edit.canRetrySpeakerEdit {controls.append(.retry)}
        if !edit.working {controls.append(.cancel)}
        if edit.canApply {controls.append(.save)}
        guard !controls.isEmpty else {return}
        let step=reverse ? -1 : 1
        let index=focused.flatMap {controls.firstIndex(of:$0)} ?? (step == 1 ? -1 : 0)
        focused=controls[(index+step+controls.count)%controls.count]
    }
}
struct SpeakerEditFailureNotice:View {
    @State private var edit=MeetingRenameCoordinator.shared
    var body:some View {
        if edit.speakerChangeFailed && edit.presentation==nil {
            HStack {
                Text(UXText.text("speakers.changeFailed"))
                Button(UXText.text("common.tryAgain")) {edit.retrySpeakerEdit()}.disabled(!edit.canEditSpeakers(edit.meeting))
                Button {edit.dismissSpeakerFailure()} label: {Image(systemName:"xmark")}.accessibilityLabel(UXText.text("common.close"))
            }.font(.system(size:13)).padding(14)
                .foregroundStyle(CassiniTheme.toastUsesInverse ? CassiniTheme.onInverse : CassiniTheme.ink)
                .buttonStyle(ToastButtonStyle(warning: false))
                .background {
                    if CassiniTheme.toastUsesInverse {
                        RoundedRectangle(cornerRadius:8).fill(CassiniTheme.inverse)
                            .shadow(color:CassiniTheme.shadow,radius:6,y:2)
                    } else {
                        RoundedRectangle(cornerRadius:8).fill(.regularMaterial)
                    }
                }
                .tint(CassiniTheme.toastUsesInverse ? CassiniTheme.inverseAccent : nil)
                .padding()
        }
    }
}

/// SwiftUI's content overlay stops below the native titlebar. Cover that remaining
/// strip in the existing frame view as well, so toolbar and traffic-light clicks
/// cannot pass behind the dialog. Removed as soon as the presentation ends.
@MainActor enum SpeakerEditorChrome {
    private static let undoGate=SpeakerUndoGate()
    private static let identifier=NSUserInterfaceItemIdentifier("speaker-titlebar-scrim")
    #if DEBUG
    static func nativeSelfTest()->[String:Bool] {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:480),styleMask:[.titled],backing:.buffered,defer:false)
        var changes=0
        let history=window.undoManager!
        history.beginUndoGrouping()
        history.registerUndo(withTarget:window) {_ in changes += 1}
        history.endUndoGrouping()
        let gate=SpeakerUndoGate()
        gate.update(window,visible:true)
        gate.undo(nil);gate.redo(nil)
        let blocked=changes == 0 && history.canUndo
        gate.update(window,visible:false)
        history.undo()
        return ["speakerModalBlocksLibraryUndo":blocked && changes == 1]
    }
    #endif
    static func update(_ window:NSWindow,visible:Bool) {
        undoGate.update(window,visible:visible)
        guard let frame=window.contentView?.superview else {return}
        let existing=frame.subviews.first {$0.identifier == identifier}
        guard visible else {existing?.removeFromSuperview();return}
        let shade=existing ?? SpeakerTitlebarShade()
        shade.identifier=identifier;shade.wantsLayer=true
        shade.setAccessibilityElement(false)
        let bottom=window.contentLayoutRect.maxY
        shade.frame=NSRect(x:0,y:bottom,width:frame.bounds.width,height:max(0,frame.bounds.maxY-bottom))
        shade.autoresizingMask=[.width,.minYMargin]
        if existing == nil {frame.addSubview(shade,positioned:.above,relativeTo:nil)}
    }
}

/// Resolve dynamic theme colours whenever the native titlebar changes appearance.
private final class SpeakerTitlebarShade:NSView {
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();refresh()}
    override func viewDidChangeEffectiveAppearance() {super.viewDidChangeEffectiveAppearance();refresh()}
    private func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor=NSColor(CassiniTheme.scrim).cgColor
        }
    }
}

/// Keep native Edit menu commands from falling through to Library undo history.
/// Menu validation runs on demand, so text editing keeps its own undo/redo.
@MainActor private final class SpeakerUndoGate:NSObject,NSMenuItemValidation {
    private struct Entry {
        let item:NSMenuItem
        weak var target:AnyObject?
    }
    private var entries:[Entry]=[]
    private weak var window:NSWindow?
    func update(_ window:NSWindow,visible:Bool) {
        guard visible else {
            for entry in entries {entry.item.target=entry.target}
            entries=[];self.window=nil
            return
        }
        self.window=window
        func install(_ menu:NSMenu) {
            for item in menu.items {
                if let submenu=item.submenu {install(submenu)}
                if ["undo:","redo:"].contains(item.action.map(NSStringFromSelector) ?? ""), item.target !== self {
                    entries.append(Entry(item:item,target:item.target as AnyObject?))
                    item.target=self
                }
            }
        }
        if let menu=NSApp.mainMenu {install(menu)}
    }
    private var editingUndo:UndoManager? {
        guard let window,let editor=window.firstResponder as? NSTextView,editor.isFieldEditor,
              let manager=editor.undoManager,manager !== window.undoManager else {return nil}
        return manager
    }
    func validateMenuItem(_ menuItem:NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) {return editingUndo?.canUndo == true}
        return editingUndo?.canRedo == true
    }
    @objc func undo(_ sender:Any?) {editingUndo?.undo()}
    @objc func redo(_ sender:Any?) {editingUndo?.redo()}
}

/// Native text fields consume Tab before SwiftUI's key handlers. Intercept it
/// for this dialog's window so the AppKit key loop cannot escape to the Library.
private struct SpeakerDialogKeyboard:NSViewRepresentable {
    var advance:(Bool)->Void
    func makeNSView(context:Context)->KeyboardView {KeyboardView()}
    func updateNSView(_ view:KeyboardView,context:Context) {view.advance=advance}
    static func dismantleNSView(_ view:KeyboardView,coordinator:()) {view.stop()}
    final class KeyboardView:NSView {
        var advance:((Bool)->Void)?
        private var monitor:Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow();stop()
            guard window != nil else {return}
            monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
                guard let self,event.window === self.window,event.keyCode == 48,
                      event.modifierFlags.intersection([.command,.control,.option]).isEmpty else {return event}
                self.advance?(event.modifierFlags.contains(.shift))
                return nil
            }
        }
        func stop() {if let monitor {NSEvent.removeMonitor(monitor)};monitor=nil}
    }
}
