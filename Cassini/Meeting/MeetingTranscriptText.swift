// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniLibrary
import CassiniKit
import SwiftUI

/// Native selection and the responder chain handle Copy/Select All. Seeking is
/// a plain click after TextKit has finished tracking, never a selection drag.
struct MeetingTranscriptText: NSViewRepresentable {
    /// M11 (GNOME): another speaker's short turn shown inline after the host's item `after`.
    struct Aside: Equatable {
        var id = 0
        var listeningWords: Set<Int> = []
        let after: Int, name: String, items: [LibraryTranscriptItem]
        /// D55.1 meeting.turn.aside: the visible text and accessible label.
        var label: String { "(" + UXText.text("meeting.turn.aside",["name":name,"text":items.map(\.text).joined(separator:" ")]) + ")" }
    }
    let items: [LibraryTranscriptItem]
    var asides: [Aside] = []
    let positionMs: Int
    let seek: (Int) -> Void
    var listeningWords: Set<Int> = []
    var canPlay = true
    var listen: (Int) -> Void = { _ in }
    var playFromHere: () -> Void = {}

    func makeNSView(context: Context) -> MeetingTurnTextView { Self.makeView() }
    static func makeView() -> MeetingTurnTextView {
        let view = MeetingTurnTextView(frame: .zero)
        view.isEditable = false; view.isSelectable = true; view.isRichText = true
        view.drawsBackground = false; view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        return view
    }
    func updateNSView(_ view: MeetingTurnTextView, context: Context) {
        update(view)
    }
    func update(_ view: MeetingTurnTextView) {
        view.seek = seek; view.listen = listen; view.playFromHere = playFromHere; view.canPlay = canPlay
        let input = MeetingTurnTextView.Input(items:items,asides:asides,words:listeningWords,canPlay:canPlay,language:UXText.language.rawValue)
        if view.input != input {
            view.input = input
            view.boundaries = Array(Set((items+asides.flatMap(\.items)).flatMap { [$0.startMs,$0.endMs] }
                + asides.compactMap { $0.items.map(\.endMs).max().map { $0+300 } })).sorted()
            view.phase = -1
        }
        var low = 0, high = view.boundaries.count
        while low < high {
            let mid = low+(high-low)/2
            if view.boundaries[mid] <= positionMs { low = mid+1 } else { high = mid }
        }
        guard view.phase != low else { return }
        view.phase = low
        let text = attributedText()
        // Playback changes attributes without destroying a person's selection.
        let ranges = view.selectedRanges
        let sameWords = view.string == text.string
        view.textStorage?.setAttributedString(text)
        if sameWords { view.selectedRanges = ranges }
        view.updateInlineButtons()
    }
    func attributedText() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        let text = NSMutableAttributedString(string: "")
        let current = CassiniTheme.nsHighlight
        func word(_ item: LibraryTranscriptItem, size: CGFloat, chip: NSColor? = nil, listening: Bool = false) -> NSAttributedString {
            var attributes: [NSAttributedString.Key:Any] = [
                .font: NSFont.systemFont(ofSize: size), .paragraphStyle: paragraph,
                .foregroundColor: item.startMs > positionMs ? CassiniTheme.nsUpcomingWordInk : CassiniTheme.nsInk,
                .cassiniSeek: Int(item.startMs), .cursor: NSCursor.pointingHand
            ]
            if let chip { attributes[.backgroundColor] = chip }
            if listening {
                attributes[.cassiniListenCurrent] = true
                attributes[.backgroundColor] = CassiniTheme.nsAccent.withAlphaComponent(chip == nil ? 0.08 : 0.18)
            }
            if item.startMs <= positionMs && positionMs < item.endMs {
                attributes[.backgroundColor] = current
                if let highlightInk = CassiniTheme.nsHighlightInk {
                    attributes[.foregroundColor] = highlightInk
                }
            }
            return NSAttributedString(string: item.text, attributes: attributes)
        }
        /// GNOME's chip: smaller text on a light tint (the accent while it plays), the name in bold.
        func chip(_ aside: Aside) -> NSAttributedString {
            // GNOME Turn.is_active: from the aside's first word to 300 ms after its last (LINGER_MS),
            // so the tint holds through the gaps between its words.
            let start = aside.items.map(\.startMs).min() ?? 0, end = aside.items.map(\.endMs).max() ?? 0
            let playing = !aside.items.isEmpty && start <= positionMs && positionMs < end + 300
            let listening = !aside.listeningWords.isEmpty
            let tint = listening ? CassiniTheme.nsAccent.withAlphaComponent(0.18) : playing ? CassiniTheme.nsAccent.withAlphaComponent(0.25) : CassiniTheme.nsInk.withAlphaComponent(0.07)
            var plain: [NSAttributedString.Key:Any] = [.font: NSFont.systemFont(ofSize: 11.5), .paragraphStyle: paragraph,
                                                        .foregroundColor: CassiniTheme.nsInk, .backgroundColor: tint]
            if let first = aside.items.first { plain[.cassiniSeek] = Int(first.startMs); plain[.cursor] = NSCursor.pointingHand }
            if listening { plain[.cassiniListenCurrent] = true }
            var bold = plain; bold[.font] = NSFont.boldSystemFont(ofSize: 11.5)
            // The catalog orders the name and the words per language; the words stay seekable.
            let marker = "\u{E000}"
            let format = "(" + UXText.text("meeting.turn.aside",["name":aside.name,"text":marker]) + ")"
            let result = NSMutableAttributedString(string: "")
            let parts = format.components(separatedBy: marker)
            for (index,part) in parts.enumerated() {
                if !part.isEmpty {
                    // The name and its punctuation in bold, as GNOME draws "<b>name:</b>".
                    let label = NSMutableAttributedString(string:part,attributes:part.contains(aside.name) ? bold : plain)
                    let range = (part as NSString).range(of:aside.name)
                    if range.location != NSNotFound && range.length > 0 {
                        label.addAttribute(.cassiniListenSpeaker,value:aside.id,range:range)
                    }
                    result.append(label)
                }
                if index < parts.count - 1 {
                    for (position,item) in aside.items.enumerated() {
                        if position > 0 { result.append(NSAttributedString(string: " ", attributes: plain)) }
                        result.append(word(item, size: 11.5, chip:tint,listening:aside.listeningWords.contains(position)))
                    }
                }
            }
            return result
        }
        for (index,item) in items.enumerated() {
            if text.length > 0 {
                var attributes: [NSAttributedString.Key:Any] = [:]
                if listeningWords.contains(index-1), listeningWords.contains(index) {
                    attributes[.cassiniListenCurrent] = true
                    attributes[.backgroundColor] = CassiniTheme.nsAccent.withAlphaComponent(0.08)
                }
                text.append(NSAttributedString(string:" ",attributes:attributes))
            }
            text.append(word(item, size:13,listening:listeningWords.contains(index)))
            for aside in asides where aside.after == index {
                text.append(NSAttributedString(string: " ")); text.append(chip(aside))
            }
        }
        return text
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MeetingTurnTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? max(1,$0) : nil } ?? 320
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        view.positionInlineButtons()
        return NSSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }
}

final class MeetingTurnTextView: NSTextView {
    struct Input: Equatable {
        let items: [LibraryTranscriptItem]
        let asides: [MeetingTranscriptText.Aside]
        let words: Set<Int>
        let canPlay: Bool
        let language: String
    }
    var input: Input?
    var boundaries: [Int64] = []
    var phase = -1
    var seek: ((Int) -> Void)?
    var listen: ((Int) -> Void)?
    var playFromHere: (() -> Void)?
    var canPlay = true
    private struct InlineName: Equatable { let row: Int; let range: NSRange; let name: String }
    private var inlineNames: [InlineName] = []
    private var inlineButtons: [InlineListenButton] = []
    final class InlineListenButton: NSButton {
        var invoke: (() -> Void)?
        var playFromHere: (() -> Void)?
        override var acceptsFirstResponder: Bool { isEnabled }
        override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
        override func becomeFirstResponder() -> Bool { defer { needsDisplay = true }; return super.becomeFirstResponder() }
        override func resignFirstResponder() -> Bool { defer { needsDisplay = true }; return super.resignFirstResponder() }
        @discardableResult func handlePlaybackKey(_ event: NSEvent) -> Bool {
            guard isEnabled else { return false }
            let modifiers = event.modifierFlags.intersection([.command,.option,.control,.shift])
            if [36,49,76].contains(event.keyCode), modifiers.isEmpty { performClick(nil); return true }
            if [36,76].contains(event.keyCode), modifiers == .shift, let playFromHere { playFromHere(); return true }
            return false
        }
        override func keyDown(with event: NSEvent) {
            if !handlePlaybackKey(event) { super.keyDown(with:event) }
        }
        override func accessibilityPerformPress() -> Bool {
            guard isEnabled else { return false }; performClick(nil); return true
        }
        init() {
            super.init(frame:.zero)
            title = ""; isBordered = false; focusRingType = .exterior
            setButtonType(.momentaryPushIn); setAccessibilityElement(true); setAccessibilityRole(.button)
            target = self; action = #selector(pressed)
        }
        required init?(coder: NSCoder) { fatalError("Programmatic inline button") }
        @objc private func pressed() { if isEnabled { invoke?() } }
        override func draw(_ dirtyRect: NSRect) {
            // TextKit draws the actual inline name. The real native button owns
            // pointer/keyboard/VoiceOver activation and the focus ring only.
            if window?.firstResponder === self {
                NSFocusRingPlacement.only.set(); NSBezierPath(roundedRect:bounds,xRadius:2,yRadius:2).fill()
            }
        }
    }
    func updateInlineButtons() {
        guard let storage = textStorage else { return }
        var names: [InlineName] = []
        storage.enumerateAttribute(.cassiniListenSpeaker,in:NSRange(location:0,length:storage.length)) { value,range,_ in
            if let row = value as? Int { names.append(.init(row:row,range:range,name:(storage.string as NSString).substring(with:range))) }
        }
        if names != inlineNames {
            for button in inlineButtons { button.removeFromSuperview() }
            inlineNames = names; inlineButtons = []
            for name in names {
                let button = InlineListenButton()
                let label = UXText.text("listen.speakerName.tooltip",["name":name.name])
                button.setAccessibilityLabel(label); button.toolTip = label
                button.setAccessibilityIdentifier("aside-listen-\(name.row)")
                button.tag = name.range.location
                button.invoke = { [weak self] in self?.listen?(name.row) }
                button.playFromHere = { [weak self] in
                    guard let self, self.canPlay else { return }; self.playFromHere?()
                }
                inlineButtons.append(button); addSubview(button)
            }
        }
        for (button,name) in zip(inlineButtons,inlineNames) {
            button.isEnabled = canPlay
            let label = UXText.text("listen.speakerName.tooltip",["name":name.name])
            button.setAccessibilityLabel(label); button.toolTip = label
        }
        positionInlineButtons()
    }
    fileprivate func positionInlineButtons() {
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer else { return }
        layout.ensureLayout(for:container)
        for button in inlineButtons {
            var range = NSRange()
            _ = storage.attribute(.cassiniListenSpeaker,at:button.tag,effectiveRange:&range)
            let glyphs = layout.glyphRange(forCharacterRange:range,actualCharacterRange:nil)
            let rect = layout.boundingRect(forGlyphRange:glyphs,in:container)
            button.frame = rect.offsetBy(dx:textContainerOrigin.x,dy:textContainerOrigin.y)
        }
    }
    override var canBecomeKeyView: Bool { false }
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(self) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(self) }
    override func layout() { super.layout(); positionInlineButtons() }
    override func accessibilityChildren() -> [Any]? { inlineButtons }
    override func keyDown(with event: NSEvent) {
        if canPlay, [36,76].contains(event.keyCode), event.modifierFlags.intersection([.shift,.control,.option,.command]) == .shift {
            playFromHere?(); return
        }
        super.keyDown(with:event)
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        guard event.clickCount == 1, selectedRange().length == 0 else { return }
        let up = convert(window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow, from: nil)
        guard hypot(up.x-point.x,up.y-point.y) < 4,
              let container = textContainer, let layout = layoutManager, let storage = textStorage else { return }
        let local = NSPoint(x: point.x-textContainerOrigin.x, y: point.y-textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container)
        guard glyph < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph,length: 1), in: container).contains(local) else { return }
        let character = layout.characterIndexForGlyph(at: glyph)
        seekAtCharacter(character)
    }
    /// Shared by mouse hit testing and the inert native regression fixture.
    func seekAtCharacter(_ character: Int) {
        guard let storage = textStorage, character >= 0, character < storage.length else { return }
        if let time = storage.attribute(.cassiniSeek,at:character,effectiveRange:nil) as? Int { seek?(time) }
    }
}

#if DEBUG
extension MeetingTranscriptText {
    /// Production attributed renderer and real native inline button, with no
    /// playback transport. Includes selection/focus preservation on clock updates.
    static func nativeSelfTest() -> [String:Bool] {
        let host: [LibraryTranscriptItem] = [.init(speaker:"claire",startMs:0,endMs:400,text:"We"),
            .init(speaker:"claire",startMs:400,endMs:800,text:"agree."),.init(speaker:"claire",startMs:1200,endMs:1800,text:"Thanks.")]
        let guest: [LibraryTranscriptItem] = [.init(speaker:"guest",startMs:850,endMs:1150,text:"Yes.")]
        let aside = Aside(id:1,listeningWords:[0],after:1,name:"Unidentified voice",items:guest)
        var sought = -1, listened = -1, played = 0
        let view = makeView(); view.frame = NSRect(x:0,y:0,width:520,height:100)
        let render = MeetingTranscriptText(items:host,asides:[aside],positionMs:-1,seek:{ sought = $0 },
                                           listen:{ listened = $0 },playFromHere:{ played += 1 })
        render.update(view)
        view.textContainer?.containerSize = NSSize(width:520,height:CGFloat.greatestFiniteMagnitude)
        view.updateInlineButtons()
        let storage = view.textStorage!, string = storage.string as NSString
        let chip = string.range(of:"Unidentified voice"), word = string.range(of:"Yes."), hostWord = string.range(of:"We")
        let chipTint = storage.attribute(.backgroundColor,at:chip.location,effectiveRange:nil) as? NSColor
        var report = ["asideHasExactListeningTint": storage.attribute(.cassiniListenCurrent,at:word.location,effectiveRange:nil) as? Bool == true && abs((chipTint?.alphaComponent ?? 0)-0.18) < 0.001 && storage.attribute(.cassiniListenCurrent,at:hostWord.location,effectiveRange:nil) == nil]
        let button = view.accessibilityChildren()?.first as? NSButton
        button?.sendAction(button?.action,to:button?.target)
        report["asideNativeListenButton"] = listened == 1 && sought == -1
        report["asideButtonAccessibility"] = button?.accessibilityRole() == .button
        report["asideButtonGeometry"] = (button?.frame.width ?? 0) > 0
        do {
            let words: [Word] = [.init(speaker:"s1",startMs:0,endMs:0,text:"same"),
                .init(speaker:"s1",startMs:1000,endMs:1150,text:"same"),
                .init(speaker:"c",startMs:950,endMs:1020,text:"same"),
                .init(speaker:"s1",startMs:800,endMs:950,text:"same"),
                .init(speaker:"b",startMs:960,endMs:970,text:"same"),
                .init(speaker:"b",startMs:975,endMs:990,text:"same"),
                .init(speaker:"s1",startMs:1020,endMs:1500,text:"same")]
            let timeline = Timeline(words,endsBoundedByAudio:true)
            let layout = TranscriptBuilder.build(timeline:timeline,hidden:[],label:{ $0 },color:{ _ in .labelColor })
            report["legacySearchUsesUniqueVisualRanges"] = layout.matchingWords("same",in:timeline) == [0,1,3,4,6,2]
        }
        report["inlineCopyHasSingleSpaces"] = storage.string == "We agree. (Unidentified voice: Yes.) Thanks."
        let prefix = string.range(of:"(Unidentified voice: "), suffix = string.range(of:")")
        let decorations = [prefix.location,prefix.location+prefix.length-2,prefix.location+prefix.length-1,suffix.location]
        var allSeek = true
        for character in decorations { sought = -1; view.seekAtCharacter(character); allSeek = allSeek && sought == 850 }
        report["chipPunctuationAndSpacesSeekFirstWord"] = allSeek
        sought = -1

        let range = NSRange(location:0,length:2); view.setSelectedRange(range)
        var edits = 0
        let observation = NotificationCenter.default.addObserver(forName:NSTextStorage.didProcessEditingNotification,object:storage,queue:.main) { _ in
            MainActor.assumeIsolated { edits += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observation) }
        let insideSamePhase = MeetingTranscriptText(items:host,asides:[aside],positionMs:-1,seek:{ sought = $0 },listen:{ listened = $0 },playFromHere:{ played += 1 })
        insideSamePhase.update(view)
        report["unchangedRowDoesNotRestyle"] = edits == 0
        let nextWord = MeetingTranscriptText(items:host,asides:[aside],positionMs:500,seek:{ sought = $0 },listen:{ listened = $0 },playFromHere:{ played += 1 })
        nextWord.update(view)
        report["clockKeepsSelectionAndInlineButton"] = view.selectedRange() == range && (view.accessibilityChildren()?.first as? NSButton) === button
        let clear = MeetingTranscriptText(items:host,asides:[.init(id:1,after:1,name:"Unidentified voice",items:guest)],positionMs:-1,seek:{ sought = $0 },listeningWords:[2],listen:{ listened = $0 },playFromHere:{ played += 1 })
        clear.update(view)
        let lastWord = string.range(of:"Thanks.")
        let bodyTint = storage.attribute(.backgroundColor,at:lastWord.location,effectiveRange:nil) as? NSColor
        if ProcessInfo.processInfo.environment["CASSINI_TRANSCRIPT_RENDER"] != nil,
           ProcessInfo.processInfo.environment["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1",
           let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            // Only the generated TextKit fixture above; never a screen/window capture.
            render.update(view)
            view.setSelectedRange(NSRange(location:0,length:0))
            view.appearance = NSAppearance(named:.aqua)
            view.drawsBackground = true; view.backgroundColor = .textBackgroundColor
            view.cacheDisplay(in:view.bounds,to:bitmap)
            if let png = bitmap.representation(using:.png,properties:[:]) {
                // The sandbox can emit its own fixture bytes; the runner writes the requested local file.
                FileHandle.standardError.write(Data(("CASSINI_TRANSCRIPT_PNG:"+png.base64EncodedString()+"\n").utf8))
            }
            clear.update(view)
        }
        report["bodyUsesEightPercentAndClearsAside"] = abs((bodyTint?.alphaComponent ?? 0)-0.08) < 0.001 && storage.attribute(.cassiniListenCurrent,at:word.location,effectiveRange:nil) == nil
        if let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.shift,timestamp:0,windowNumber:0,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36) { view.keyDown(with:event) }
        report["focusedTranscriptShiftReturnPlays"] = played == 1 && sought == -1
        // Use an actual key-view loop without changing global keyboard settings.
        // Selecting text by mouse stays possible; Tab skips it or leaves it.
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:180),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.autorecalculatesKeyViewLoop = false
        window.setAccessibilityIdentifier("cassini-library-window")
        let content = NSView(frame:window.contentLayoutRect)
        let before = MeetingTurnTextView.InlineListenButton(), after = MeetingTurnTextView.InlineListenButton()
        before.frame = NSRect(x:0,y:0,width:30,height:20); after.frame = NSRect(x:550,y:0,width:30,height:20)
        content.addSubview(before); content.addSubview(view); content.addSubview(after)
        window.contentView = content; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        if let button = button as? MeetingTurnTextView.InlineListenButton {
            before.nextKeyView = view; view.nextKeyView = button; button.nextKeyView = after; after.nextKeyView = before
            report["inlineButtonFocusableWithoutFullKeyboardAccess"] = button.acceptsFirstResponder && button.canBecomeKeyView
            window.makeFirstResponder(before); window.selectNextKeyView(before)
            report["tabSkipsSelectableTranscript"] = !view.canBecomeKeyView && window.firstResponder === button
            window.makeFirstResponder(view); view.insertTab(nil)
            report["pointerFocusedTranscriptTabAdvances"] = window.firstResponder === button
            window.makeFirstResponder(view); view.insertBacktab(nil)
            report["pointerFocusedTranscriptBacktabAdvances"] = window.firstResponder === before
            window.makeFirstResponder(before); button.needsDisplay = false
            window.makeFirstResponder(button)
            report["inlineFocusInvalidatesRing"] = window.firstResponder === button && button.needsDisplay
            button.needsDisplay = false; window.makeFirstResponder(before)
            report["inlineBlurInvalidatesRing"] = button.needsDisplay
            window.makeFirstResponder(button)
            var presses = 0
            let invoke = button.invoke; button.invoke = { presses += 1; invoke?() }
            func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
                NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:window.windowNumber,context:nil,
                    characters:code == 49 ? " " : (code == 76 ? "\u{03}" : "\r"),charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
            }
            for code: UInt16 in [36,49,76] { button.keyDown(with:key(code)) }
            report["inlineReturnSpaceKeypadActivate"] = presses == 3 && listened == 1 && window.firstResponder === button
            let previousPlayed = played
            for code: UInt16 in [36,76] { button.keyDown(with:key(code,.shift)) }
            report["inlineShiftReturnKeypadPlayAndKeepFocus"] = played == previousPlayed+2 && window.firstResponder === button
            button.isEnabled = false
            report["disabledInlineButtonCannotFocusOrActivate"] = !button.acceptsFirstResponder && !button.canBecomeKeyView && !button.handlePlaybackKey(key(49))
            button.isEnabled = true
            if let previous = MeetingNavigation.shared.detail {
                let frozen = MeetingDetailModel(meeting:previous.meeting,frozen:true)
                MeetingNavigation.shared.detail = frozen
                defer { frozen.close(); MeetingNavigation.shared.detail = previous }
                let playing = frozen.isPlaying, count = presses
                window.makeFirstResponder(button)
                report["focusedInlineSpacePrecedesPlayer"] = AppDelegate.handleListeningSelfTest(key(49)) == nil && presses == count+1 && frozen.isPlaying == playing
            } else { report["focusedInlineSpacePrecedesPlayer"] = false }
        }
        let playedBeforeButtonChecks = played
        if let button = button as? MeetingTurnTextView.InlineListenButton {
            listened = -1
            if let space = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:" ",charactersIgnoringModifiers:" ",isARepeat:false,keyCode:49) {
                report["inlineButtonSpaceInvokesListen"] = button.handlePlaybackKey(space) && listened == 1 && played == playedBeforeButtonChecks
                button.isEnabled = false; listened = -1
                report["disabledInlineButtonDoesNotConsumeSpace"] = !button.handlePlaybackKey(space) && listened == -1
                button.isEnabled = true
            }
            listened = -1
            report["focusedButtonPrecedesBarePlayback"] = AppDelegate.pressPlaybackButton(button) && listened == 1 && played == playedBeforeButtonChecks
            button.isEnabled = false
            report["disabledButtonNotPressedByMediaRouter"] = !AppDelegate.pressPlaybackButton(button)
            button.isEnabled = true
            if let enter = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.shift,timestamp:0,windowNumber:0,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36) {
                report["inlineButtonShiftReturnPlaysHost"] = button.handlePlaybackKey(enter) && played == playedBeforeButtonChecks+1
            }
        }
        return report
    }
}
#endif
