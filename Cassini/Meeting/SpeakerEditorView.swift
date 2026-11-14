// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

/// Local voice enrollment is offered only for a prepared, separated source.
struct SpeakerEditorView:View {
    @State private var edit=MeetingRenameCoordinator.shared
    @State private var nameFocused=false
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
            .onAppear {SpeakerEditorChrome.focusName()}
            .onChange(of:edit.name) { _,new in
                if let id=edit.savedVoiceID,
                   SavedVoicesController.shared.voices.first(where:{$0.id == id})?.name != new { edit.savedVoiceID=nil }
            }
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
        SpeakerActionButton(control:.sample,
                            title:UXText.text(detail?.speakerSample.active == true ? "common.stop" : "speakers.playSample"),
                            enabled:!edit.working && detail?.canPlay == true && edit.speakerSampleRange != nil,
                            symbol:detail?.speakerSample.active == true ? "stop.fill" : "play.fill") {
            guard let detail else {return}
            if detail.speakerSample.active {detail.speakerSample.cancel()}
            else if let range=edit.speakerSampleRange {detail.playSpeakerSample(range)}
        }.frame(width:30,height:30)
            .background(CassiniTheme.neutralPillFill,in:Circle())
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
            SpeakerNameField(text:$edit.name,enabled:!edit.working,
                             focusChanged:{nameFocused=$0},submit:{if edit.canApply {edit.apply()}})
                .frame(maxWidth:.infinity).padding(10)
                .background(CassiniTheme.field,in:RoundedRectangle(cornerRadius:6))
                .overlay(RoundedRectangle(cornerRadius:6).stroke(nameFocused ? CassiniTheme.accent : CassiniTheme.fieldLine,lineWidth:1))
        }
    }
    private var savedVoices:some View {
        VStack(alignment:.leading,spacing:8) {
            Text(UXText.text("common.savedVoices")).fontWeight(.semibold)
            if SavedVoicesController.shared.voices.isEmpty {
                Text(UXText.text("savedVoices.empty")).foregroundStyle(CassiniTheme.ink2)
            } else {
                ScrollView {
                    VStack(alignment:.leading,spacing:8) {
                        ForEach(SavedVoicesController.shared.voices) { voice in
                            Button(voice.name) { edit.name=voice.name; edit.savedVoiceID=voice.id }
                                .buttonStyle(.plain).disabled(edit.working)
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxHeight:100)
            }
            if let duplicate=VoiceSelection.matchingName(edit.name,voices:SavedVoicesController.shared.voices).first,
               edit.savedVoiceID == nil {
                Text(UXText.text("speakers.duplicate.notice",["name":duplicate.name]))
                HStack {
                    Button(UXText.text("speakers.duplicate.samePerson")) { edit.savedVoiceID=duplicate.id }
                    Button(UXText.text("speakers.duplicate.someoneElse")) { edit.savedVoiceID=nil }
                }
            }
        }.padding(12).background(CassiniTheme.surface,in:RoundedRectangle(cornerRadius:12))
    }
    private var rememberVoice:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(alignment:.top,spacing:12) {
                VStack(alignment:.leading,spacing:5) {
                    Text(UXText.text("speakers.rememberVoice.title"))
                    Text(UXText.text(edit.voiceEnrollment == nil ? "speakers.rememberVoice.notPrepared":"speakers.rememberVoice.cardBody.computer.unnamed"))
                        .accessibilityIdentifier("speaker-remember-explanation")
                        .font(.system(size:12)).foregroundStyle(CassiniTheme.ink2)
                        .fixedSize(horizontal:false,vertical:true)
                }
                Spacer(minLength:0)
                Toggle(UXText.text("speakers.rememberVoice.title"),isOn:$edit.rememberVoice)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(edit.working || edit.voiceEnrollment == nil)
                    .accessibilityIdentifier("speaker-remember-voice")
            }
        }.padding(14).background(CassiniTheme.surface,in:RoundedRectangle(cornerRadius:12))
                .overlay(RoundedRectangle(cornerRadius:12).stroke(CassiniTheme.lineSoft,lineWidth:1))
    }
    private var failure:some View {
        HStack(spacing:10) {
            Text(UXText.text("speakers.changeFailed")).foregroundStyle(CassiniTheme.error)
                .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("speaker-change-error")
            SpeakerActionButton(control:.retry,title:UXText.text("common.tryAgain"),enabled:edit.canRetrySpeakerEdit) {edit.retrySpeakerEdit()}.fixedSize()
        }.padding(12).background(CassiniTheme.errorTint,in:RoundedRectangle(cornerRadius:7))
    }
    private func footer(_ meeting:LibraryMeeting,_ speaker:MeetingSpeaker)->some View {
        HStack {
            SpeakerMergeMenu(speakers:meeting.speakers.filter {$0.id != speaker.id},
                             enabled:!edit.working && meeting.speakers.count>1,
                             merge:{edit.mergeSpeaker(into:$0)})
                .fixedSize()
            Spacer(minLength:0)
            if edit.working {ProgressView().controlSize(.small)}
            SpeakerActionButton(control:.cancel,title:UXText.text("common.cancel"),enabled:!edit.working,key:"\u{1b}") {edit.cancel()}.fixedSize()
            SpeakerActionButton(control:.save,title:UXText.text("speakers.saveName"),enabled:edit.canApply,key:"\r") {edit.apply()}.fixedSize()
        }
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
    private final class ControlReference {
        weak var value:NSControl?
        init(_ value:NSControl) {self.value=value}
    }
    private static var controls:[SpeakerEditorControl:ControlReference]=[:]
    private static var initialFocusPending=false
    static func register(_ control:NSControl,as key:SpeakerEditorControl) {
        controls[key]=ControlReference(control)
        completeInitialFocus()
    }
    static func focusName() {initialFocusPending=true;completeInitialFocus()}
    private static func completeInitialFocus() {
        guard initialFocusPending,let field=controls[.name]?.value,field.isEnabled,
              let window=field.window else {return}
        if window.makeFirstResponder(field) {initialFocusPending=false}
    }
    private static func isFocused(_ control:NSControl,in window:NSWindow)->Bool {
        guard let responder=window.firstResponder else {return false}
        // Editing an NSTextField makes its shared field editor first responder.
        // Resolve that owner before choosing the next native dialog control.
        return responder === control || responder === control.currentEditor()
    }
    static func advanceFocus(reverse:Bool,in window:NSWindow) {
        let available=SpeakerEditorControl.allCases.compactMap {controls[$0]?.value}.filter {
            $0.window === window && $0.isEnabled && $0.canBecomeKeyView
        }
        guard !available.isEmpty else {return}
        let index=available.firstIndex {isFocused($0,in:window)} ?? (reverse ? 0 : -1)
        for distance in 1...available.count {
            let next=available[(index+(reverse ? -distance : distance)+available.count)%available.count]
            if window.makeFirstResponder(next) {next.scrollToVisible(next.bounds);return}
        }
    }
    private static let undoGate=SpeakerUndoGate()
    private static let identifier=NSUserInterfaceItemIdentifier("speaker-titlebar-scrim")
    static func dismiss() {controls=[:];initialFocusPending=false;undoGate.reset()}
    #if DEBUG
    static func nativeSelfTest()->[String:Bool] {
        let savedControls=controls,savedPending=initialFocusPending
        controls=[:];initialFocusPending=false
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:480),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        defer {window.close();controls=savedControls;initialFocusPending=savedPending}
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
        let name=SpeakerNameField.Field(frame:NSRect(x:0,y:40,width:200,height:20))
        name.stringValue="Marta"
        let save=SpeakerActionButton.Button(frame:NSRect(x:220,y:40,width:100,height:24))
        let outside=SpeakerActionButton.Button(frame:NSRect(x:340,y:40,width:100,height:24))
        window.contentView!.addSubview(name);window.contentView!.addSubview(save);window.contentView!.addSubview(outside)
        register(name,as:.name);register(popup,as:.merge);register(save,as:.save)
        name.nextKeyView=outside
        window.makeFirstResponder(name)
        var cycle=isFocused(name,in:window)
        advanceFocus(reverse:false,in:window);cycle=cycle && isFocused(popup,in:window)
        advanceFocus(reverse:false,in:window);cycle=cycle && isFocused(save,in:window)
        advanceFocus(reverse:false,in:window);cycle=cycle && isFocused(name,in:window)
        advanceFocus(reverse:true,in:window);cycle=cycle && isFocused(save,in:window)
        window.makeFirstResponder(name);save.isEnabled=false
        advanceFocus(reverse:true,in:window)
        let skipped=isFocused(popup,in:window)
        window.makeFirstResponder(nil);popup.isEnabled=false
        return ["speakerModalBlocksLibraryUndo":blocked && changes == 1,
                "speakerMergeHasNativeKeyboardFocus":nativeFocus && !popup.acceptsFirstResponder && !popup.canBecomeKeyView,
                "speakerNativeFocusCycle":cycle,"speakerNativeFocusSkipsDisabled":skipped]
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
    let merge:(String)->Void
    func makeNSView(context:Context)->Popup {
        let button=Popup(frame:.zero,pullsDown:true)
        button.font = .systemFont(ofSize:13)
        button.setAccessibilityIdentifier("speaker-merge-menu")
        SpeakerEditorChrome.register(button,as:.merge)
        return button
    }
    func updateNSView(_ button:Popup,context:Context) {
        button.merge=merge
        SpeakerEditorChrome.register(button,as:.merge)
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
    }
    final class Popup:NSPopUpButton {
        struct Entry:Equatable {let id:String;let title:String}
        var entries:[Entry]=[]
        var merge:((String)->Void)?
        override var acceptsFirstResponder:Bool {isEnabled}
        override var canBecomeKeyView:Bool {isEnabled && !isHiddenOrHasHiddenAncestor}
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


/// Every dialog control participates in this one native responder cycle.
enum SpeakerEditorControl:CaseIterable {
    case sample,name,merge,retry,cancel,save
    var identifier:String {
        switch self {
        case .sample:return "speaker-play-sample"
        case .name:return "speaker-name-field"
        case .merge:return "speaker-merge-menu"
        case .retry:return "speaker-retry"
        case .cancel:return "speaker-cancel"
        case .save:return "speaker-save-name"
        }
    }
}

private struct SpeakerActionButton:NSViewRepresentable {
    let control:SpeakerEditorControl
    let title:String
    let enabled:Bool
    var symbol:String?=nil
    var key:String=""
    let action:()->Void
    func makeNSView(context:Context)->Button {
        let button=Button(frame:.zero)
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize:13)
        button.target=button;button.action=#selector(Button.press(_:))
        button.setAccessibilityIdentifier(control.identifier)
        SpeakerEditorChrome.register(button,as:control)
        return button
    }
    func updateNSView(_ button:Button,context:Context) {
        button.title=title;button.setAccessibilityLabel(title)
        button.invoke=action;button.isEnabled=enabled && context.environment.isEnabled
        button.keyEquivalent=key;button.keyEquivalentModifierMask=[]
        button.isBordered=symbol == nil
        button.image=symbol.flatMap {NSImage(systemSymbolName:$0,accessibilityDescription:nil)}
        button.imagePosition=symbol == nil ? .noImage : .imageOnly
        SpeakerEditorChrome.register(button,as:control)
    }
    final class Button:NSButton {
        var invoke:(()->Void)?
        override var acceptsFirstResponder:Bool {isEnabled}
        override var canBecomeKeyView:Bool {isEnabled && !isHiddenOrHasHiddenAncestor}
        @objc func press(_ sender:Any?) {if isEnabled {invoke?()}}
        override func keyDown(with event:NSEvent) {
            if [36,49,76].contains(event.keyCode),event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty {
                performClick(nil)
            } else {super.keyDown(with:event)}
        }
    }
}

private struct SpeakerNameField:NSViewRepresentable {
    @Binding var text:String
    let enabled:Bool
    let focusChanged:(Bool)->Void
    let submit:()->Void
    func makeCoordinator()->Coordinator {Coordinator(text:$text,focusChanged:focusChanged,submit:submit)}
    func makeNSView(context:Context)->Field {
        let field=Field(frame:.zero)
        field.stringValue=text;field.font = .systemFont(ofSize:13)
        field.isBordered=false;field.isBezeled=false;field.drawsBackground=false
        field.focusRingType = .none;field.usesSingleLineMode=true
        field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        field.setAccessibilityIdentifier(SpeakerEditorControl.name.identifier)
        field.setAccessibilityLabel(UXText.text("speakers.nameLabel"))
        field.delegate=context.coordinator
        SpeakerEditorChrome.register(field,as:.name)
        return field
    }
    func updateNSView(_ field:Field,context:Context) {
        context.coordinator.text=$text
        context.coordinator.focusChanged=focusChanged;context.coordinator.submit=submit
        if field.stringValue != text {field.stringValue=text}
        field.isEnabled=enabled && context.environment.isEnabled
        field.textColor=CassiniTheme.nsInk
        SpeakerEditorChrome.register(field,as:.name)
    }
    final class Field:NSTextField {
        private let editingUndo=UndoManager()
        override var undoManager:UndoManager? {editingUndo}
        override var acceptsFirstResponder:Bool {isEnabled && isEditable}
        override var canBecomeKeyView:Bool {isEnabled && isEditable && !isHiddenOrHasHiddenAncestor}
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            SpeakerEditorChrome.register(self,as:.name)
        }
    }
    final class Coordinator:NSObject,NSTextFieldDelegate {
        var text:Binding<String>
        var focusChanged:(Bool)->Void
        var submit:()->Void
        init(text:Binding<String>,focusChanged:@escaping(Bool)->Void,submit:@escaping()->Void) {
            self.text=text;self.focusChanged=focusChanged;self.submit=submit;super.init()
        }
        func controlTextDidChange(_ notification:Notification) {
            if let field=notification.object as? NSTextField {text.wrappedValue=field.stringValue}
        }
        func controlTextDidBeginEditing(_ notification:Notification) {focusChanged(true)}
        func controlTextDidEndEditing(_ notification:Notification) {
            controlTextDidChange(notification);focusChanged(false)
        }
        func control(_ control:NSControl,textView:NSTextView,doCommandBy command:Selector)->Bool {
            guard command == NSSelectorFromString("insertNewline:") else {return false}
            submit();return true
        }
    }
}
