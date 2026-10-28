// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import Carbon

struct RecordingHotKey: Codable, Equatable, Sendable {
    let code: UInt32
    let flags: UInt32
    let character: String
    let name: String
    static let standard = Self(code:UInt32(kVK_ANSI_R),flags:UInt32(optionKey | cmdKey),character:"r",name:"R")
    var valid: Bool {
        code < 128 && character.count == 1 && !name.isEmpty && name.count <= 12 &&
        flags & ~UInt32(cmdKey | optionKey | controlKey | shiftKey) == 0 && flags & UInt32(cmdKey | optionKey | controlKey) != 0
    }
    var glyph: String {
        (flags & UInt32(controlKey) != 0 ? "⌃" : "") + (flags & UInt32(optionKey) != 0 ? "⌥" : "") +
        (flags & UInt32(shiftKey) != 0 ? "⇧" : "") + (flags & UInt32(cmdKey) != 0 ? "⌘" : "") + name
    }
    var key: KeyEquivalent { KeyEquivalent(character.first ?? "r") }
    var modifiers: SwiftUI.EventModifiers {
        var value: SwiftUI.EventModifiers = []
        if flags & UInt32(cmdKey) != 0 { value.insert(.command) }
        if flags & UInt32(optionKey) != 0 { value.insert(.option) }
        if flags & UInt32(controlKey) != 0 { value.insert(.control) }
        if flags & UInt32(shiftKey) != 0 { value.insert(.shift) }
        return value
    }
    @MainActor static var saved: Self {
        guard let bytes = RecordingPreferences.defaults.data(forKey:"CassiniRecordingHotKey"),
              let choice = try? JSONDecoder().decode(Self.self,from:bytes), choice.valid else { return .standard }
        return choice
    }
    init(code: UInt32, flags: UInt32, character: String, name: String) {
        self.code = code; self.flags = flags; self.character = character; self.name = name
    }
    init?(event: NSEvent) {
        var flags: UInt32 = 0
        if event.modifierFlags.contains(.command) { flags |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { flags |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { flags |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { flags |= UInt32(shiftKey) }
        guard let character = event.charactersIgnoringModifiers?.lowercased(), character.count == 1 else { return nil }
        let special: [UInt16:String] = [36:"↩",48:"⇥",49:"␣",51:"⌫",53:"⎋",117:"⌦",123:"←",124:"→",125:"↓",126:"↑"]
        let functions: [UInt16:Int] = [122:1,120:2,99:3,118:4,96:5,97:6,98:7,100:8,101:9,109:10,103:11,111:12,105:13,107:14,113:15,106:16,64:17,79:18,80:19,90:20]
        self.init(code:UInt32(event.keyCode),flags:flags,character:character,
                  name:special[event.keyCode] ?? functions[event.keyCode].map { "F\($0)" } ?? character.uppercased())
        guard valid else { return nil }
    }
}
