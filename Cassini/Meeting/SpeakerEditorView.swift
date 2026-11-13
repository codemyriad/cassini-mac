// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

/// WP6: a single column dialog. Voice profiles are not yet prepared on Mac;
/// naming stays available without pretending that a voiceprint has been saved.
struct SpeakerEditorView:View {
    @State private var edit=MeetingRenameCoordinator.shared
    private enum Control:Hashable {case sample,name,merge,retry,cancel,save}
    @FocusState private var focused:Control?
    @State private var lastFocused:Control = .name
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
            .onChange(of:focused) {_,value in if let value {lastFocused=value}}
            .onAppear {focused = .name;SpeakerEditorChrome.advanceFocus=advanceFocus}
            .onDisappear {SpeakerEditorChrome.dismiss();detail?.speakerSample.cancel()}
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
            SpeakerMergeMenu(speakers:meeting.speakers.filter {$0.id != speaker.id},
                             enabled:!edit.working && meeting.speakers.count>1,
                             focusRequested:(focused ?? lastFocused) == .merge,
                             onFocus:{lastFocused = .merge;focused=nil},
                             merge:{edit.mergeSpeaker(into:$0)})
                .fixedSize()
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
        let current=focused ?? lastFocused
        let index=controls.firstIndex(of:current) ?? (step == 1 ? -1 : 0)
        let target=controls[(index+step+controls.count)%controls.count]
        if current == .merge && target != .merge {NSApp.keyWindow?.makeFirstResponder(nil)}
        lastFocused=target
        // The native popup owns its AppKit responder directly; FocusState owns
        // the SwiftUI controls and must release the name field before that move.
        focused=target == .merge ? nil : target
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
    static var advanceFocus:((Bool)->Void)?
    private static let undoGate=SpeakerUndoGate()
    private static let identifier=NSUserInterfaceItemIdentifier("speaker-titlebar-scrim")
    static func dismiss() {advanceFocus=nil;undoGate.reset()}
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
        let popup=SpeakerMergeMenu.Popup(frame:NSRect(x:0,y:0,width:120,height:24),pullsDown:true)
        popup.addItem(withTitle:UXText.text("speakers.mergeInto"))
        window.contentView!.addSubview(popup)
        let nativeFocus=window.makeFirstResponder(popup) && window.firstResponder === popup && popup.canBecomeKeyView
        window.makeFirstResponder(nil);popup.isEnabled=false
        return ["speakerModalBlocksLibraryUndo":blocked && changes == 1,
                "speakerMergeHasNativeKeyboardFocus":nativeFocus && !popup.acceptsFirstResponder && !popup.canBecomeKeyView]
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
    func reset() {
        for entry in entries {entry.item.target=entry.target}
        entries=[];window=nil
    }
    func update(_ window:NSWindow,visible:Bool) {
        guard visible else {reset();return}
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

/// SwiftUI Menu does not acquire an AppKit first responder when focused on Mac.
/// Use the native popup so Tab followed by Space opens the actual merge menu.
private struct SpeakerMergeMenu:NSViewRepresentable {
    let speakers:[MeetingSpeaker]
    let enabled:Bool
    let focusRequested:Bool
    let onFocus:()->Void
    let merge:(String)->Void
    func makeNSView(context:Context)->Popup {
        let button=Popup(frame:.zero,pullsDown:true)
        button.font = .systemFont(ofSize:13)
        button.setAccessibilityIdentifier("speaker-merge-menu")
        return button
    }
    func updateNSView(_ button:Popup,context:Context) {
        button.merge=merge;button.onFocus=onFocus
        let entries=speakers.map {Popup.Entry(id:$0.id,title:$0.displayName)}
        if button.entries != entries {
            button.entries=entries;button.removeAllItems()
            button.addItem(withTitle:UXText.text("speakers.mergeInto"))
            for entry in entries {
                let item=NSMenuItem(title:entry.title,action:#selector(Popup.choose(_:)),keyEquivalent:"")
                item.representedObject=entry.id;item.target=button
                item.setAccessibilityIdentifier("speaker-merge-into-"+entry.id)
                button.menu?.addItem(item)
            }
        }
        button.isEnabled=enabled && context.environment.isEnabled
        button.focusRequested=focusRequested
        DispatchQueue.main.async { [weak button] in button?.requestFocus() }
    }
    final class Popup:NSPopUpButton {
        struct Entry:Equatable {let id:String;let title:String}
        var entries:[Entry]=[]
        var focusRequested=false
        var onFocus:(()->Void)?
        var merge:((String)->Void)?
        override var acceptsFirstResponder:Bool {isEnabled}
        override var canBecomeKeyView:Bool {isEnabled && !isHiddenOrHasHiddenAncestor}
        override func becomeFirstResponder()->Bool {
            let accepted=super.becomeFirstResponder()
            if accepted {onFocus?()}
            return accepted
        }
        override func viewDidMoveToWindow() {super.viewDidMoveToWindow();requestFocus()}
        func requestFocus() {
            guard focusRequested,isEnabled,let window,window.firstResponder !== self else {return}
            window.makeFirstResponder(self)
        }
        override func keyDown(with event:NSEvent) {
            if [36,49,76].contains(event.keyCode),event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty {
                performClick(nil)
            } else {super.keyDown(with:event)}
        }
        @objc func choose(_ sender:NSMenuItem) {
            if isEnabled,let id=sender.representedObject as? String {merge?(id)}
        }
    }
}
