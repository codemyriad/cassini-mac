// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

struct RecordingMenuPayload: Codable, Sendable {
    struct Level: Codable, Sendable { let label: String; let value: Float; let silent: Bool }
    struct Action: Codable, Sendable, Identifiable { let id: String; let title: String; let shortcut: String? }
    let header: String
    let title: String
    let levels: [Level]
    let actions: [Action]
    let noSleep: String?
    let sourceLines: [String]?
    let assertionHeld: Bool
    var json: String { (try? String(data:JSONEncoder().encode(self),encoding:.utf8)) ?? "{}" }
    @MainActor init(recorder: RecordingController, runtime: RecordingRuntime) {
        header = UXText.text("hidden.status",["liveBig":LibraryFormat.liveBig(RecordingOverview.elapsedMs)])
        title = RecordingOverview.title
        levels = [
            .init(label:UXText.text("common.yourMicrophone"),value:RecordingOverview.levels["microphone",default:0],silent:RecordingOverview.microphoneSilent),
            .init(label:UXText.text("common.theOthers"),value:RecordingOverview.levels["output",default:0],silent:false)
        ]
        actions = [
            .init(id:"stop",title:UXText.text("hidden.menu.stopRecording"),shortcut:runtime.shortcut.registered ? RecordingShortcut.glyph : nil),
            .init(id:"open",title:UXText.text("hidden.openCassini"),shortcut:nil)
        ]
        assertionHeld = runtime.power.held
        noSleep = assertionHeld ? UXText.text("hidden.menu.noSleep") : nil
        var lines: [String] = []
        if let first = CaptureCollection.shared.first {
            if first.input.failedSides.contains(.me) { lines.append(UXText.text("errors.micPermission.line")) }
            if first.snapshot.others && !first.snapshot.browserAlive {
                if first.input.failedSides.contains(.others) { lines.append(UXText.text("errors.othersPermission.line")) }
                else if first.snapshot.fallbackReason != nil { lines.append(UXText.text("errors.othersFallback.line")) }
            }
        }
        sourceLines = lines.isEmpty ? nil : lines
    }
}

struct RecordingStatusLabel: View {
    @State private var recorder = RecordingController.shared
    @State private var elapsedMs: Int64 = 0
    var body: some View {
        HStack(spacing:5) {
            Circle().fill(LibraryTheme.red).frame(width:8,height:8)
            Text(LibraryFormat.liveBadge(elapsedMs)).monospacedDigit().fontWeight(.semibold)
        }.accessibilityLabel(UXText.text("hidden.status",["liveBig":LibraryFormat.liveBig(elapsedMs)]))
            .accessibilityIdentifier("recording-menu-bar")
            .task {
                // TimelineView inside a MenuBarExtra label can re-enter the
                // status-button update loop during app launch on current macOS.
                while !Task.isCancelled {
                    elapsedMs = RecordingOverview.elapsedMs
                    do { try await Task.sleep(for:.seconds(1)) } catch { return }
                }
            }
    }
}
struct RecordingStatusMenu: View {
    @State private var recorder = RecordingController.shared
    @State private var power = RecordingRuntime.shared.power
    @State private var hovered: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        TimelineView(.periodic(from:.now,by:1)) { _ in
            let payload = RecordingMenuPayload(recorder:recorder,runtime:RecordingRuntime.shared)
            VStack(alignment:.leading,spacing:8) {
                #if DEBUG
                if RecordingFixture.enabled { RecordingMenuFixturePayload(json:payload.json).frame(width:1,height:1).opacity(0.01) }
                #endif
                VStack(alignment:.leading,spacing:4) {
                    Text(payload.header).fontWeight(.bold)
                    Text(payload.title).font(.system(size:12)).foregroundStyle(LibraryTheme.dim).lineLimit(2)
                }.padding(.horizontal,6)
                ForEach(Array(payload.levels.enumerated()),id:\.offset) { _,level in
                    HStack(spacing:8) {
                        Text(level.label).fontWeight(level.silent ? .semibold : .regular).foregroundStyle(level.silent ? LibraryTheme.amber : Color.primary)
                            .frame(width:120,alignment:.leading)
                        RecordingLevelMeter(level:level.value,silent:level.silent,label:level.label).frame(height:4)
                    }.padding(.horizontal,6)
                }
                Divider()
                ForEach(payload.actions) { item in action(item) }
                if let lines = payload.sourceLines {
                    Divider()
                    ForEach(Array(lines.enumerated()),id:\.offset) { _,line in Text(line).font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim).fixedSize(horizontal:false,vertical:true).padding(.horizontal,6) }
                }
                if let line = RecordingOverview.diskLine { Divider(); Text(line).font(.system(size:11.5)).foregroundStyle(LibraryTheme.amber).fixedSize(horizontal:false,vertical:true).padding(.horizontal,6) }
                if let line = payload.noSleep { Divider(); Text(line).font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim).padding(.horizontal,6).accessibilityIdentifier("recording-no-sleep") }
            }.font(.system(size:13)).padding(10).frame(width:300).accessibilityElement(children:.contain)
                .accessibilityLabel(UXText.text("app.name")).accessibilityIdentifier("recording-menu-payload")
                .accessibilityValue(fixturePayload(payload))
        }
    }
    private func fixturePayload(_ payload: RecordingMenuPayload) -> String {
        #if DEBUG
        if RecordingFixture.enabled { return payload.json }
        #endif
        return ""
    }
    @ViewBuilder private func action(_ item: RecordingMenuPayload.Action) -> some View {
        let button = Button {
            dismiss()
            switch item.id {
            case "stop": RecordingOverview.stop()
            default: RecordCoordinator.shared.openCurrent()
            }
        } label: {
            HStack {
                Text(item.title); Spacer()
                if let shortcut = item.shortcut { Text(shortcut).font(.system(size:11.5)) }
            }.padding(.horizontal,6).frame(height:24).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(hovered == item.id ? Color.white : Color.primary)
            .background(hovered == item.id ? Color.accentColor : Color.clear,in:RoundedRectangle(cornerRadius:4))
            .onHover { over in hovered = over ? item.id : nil }.accessibilityIdentifier("recording-menu-" + item.id)
        if item.id == "stop" { button.keyboardShortcut(RecordingRuntime.shared.shortcut.choice.key,modifiers:RecordingRuntime.shared.shortcut.choice.modifiers) }
        else { button }
    }
}

#if DEBUG
/// AXGroup has no reliable value on macOS15. Expose the actual debug payload
/// through a native read-only text node, absent from Release and normal launches.
private struct RecordingMenuFixturePayload: NSViewRepresentable {
    let json: String
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString:json)
        field.setAccessibilityIdentifier("recording-menu-fixture-payload"); return field
    }
    func updateNSView(_ field: NSTextField, context: Context) { field.stringValue = json }
}
#endif
