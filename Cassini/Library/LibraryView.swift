import SwiftUI
import CassiniLibrary

private enum LibraryTheme {
    static let dim = Color(nsColor: .secondaryLabelColor)
    static let sidebar = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .windowBackgroundColor : NSColor(red: 241/255, green: 240/255, blue: 245/255, alpha: 1) })
    static let chip = Color(nsColor: .quaternaryLabelColor).opacity(0.35)
    static let red = Color(nsColor: .systemRed)
}
struct LibraryView: View {
    @State private var store = LibraryStore()
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Group {
            if store.loaded && store.meetings.isEmpty && !store.offline { firstRun }
            else { split }
        }
        .font(.system(size: 13))
        .navigationTitle(UXText.text("library.title"))
        .toolbar {
            ToolbarItem(placement: .navigation) { toolbarControl }
        }
        .background(WindowAccessor { window in
            guard let window else { return }
            window.setAccessibilityIdentifier("cassini-library-window")
            window.toolbarStyle = .unified
            #if DEBUG
            ScreenshotFixture.prepareLibrary(window)
            #endif
        })
        .onAppear {
            LegacyOpening.handler = { url in openWindow(id: "legacy-viewer", value: LegacyRoute(url: url, autoplay: false)) }
            store.start()
        }
        .onDisappear { store.stop() }
        .onOpenURL { openWindow(id: "legacy-viewer", value: LegacyRoute(url: $0, autoplay: false)) }
        .preferredColorScheme(store.context.screenshot ? .light : nil)
        .accessibilityIdentifier(store.loaded ? "library-ready" : "library-loading")
    }
    private var split: some View {
        NavigationSplitView {
            List(selection: $store.selectedKey) {
                ForEach(store.groups, id: \.title) { group in
                    Section {
                        ForEach(group.meetings, id: \.libraryKey) { meeting in
                            row(meeting).tag(meeting.libraryKey)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                                .accessibilityIdentifier("meeting-" + meeting.libraryKey)
                        }
                    } header: {
                        Text(group.title).font(.system(size: 11.5, weight: .bold)).foregroundStyle(LibraryTheme.dim).textCase(nil)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(LibraryTheme.sidebar)
            .navigationSplitViewColumnWidth(min: 400, ideal: 400, max: 400)
            .accessibilityLabel(UXText.text("library.listPane.a11y"))
        } detail: {
            if let meeting = store.selected { preview(meeting) }
            else { Color(nsColor: .textBackgroundColor) }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
    }
    private var toolbarControl: some View {
        Group {
            if let live = store.meetings.first(where: { $0.state.lifecycle == .recording }) {
                // Read-only header placeholder until UX5 owns transport/levels.
                HStack(spacing: 8) {
                    Circle().fill(LibraryTheme.red).frame(width: 10, height: 10)
                    Text(LibraryFormat.liveBadge(live.state.liveMs ?? 0)).fontWeight(.semibold).monospacedDigit().foregroundStyle(LibraryTheme.red)
                    VStack(spacing: 3) {
                        Capsule().fill(LibraryTheme.red.opacity(0.6)).frame(width: 30, height: 4)
                        Capsule().fill(LibraryTheme.red.opacity(0.3)).frame(width: 30, height: 4)
                    }.accessibilityHidden(true)
                    Text(UXText.text("common.stop")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).frame(height: 26).background(LibraryTheme.red, in: RoundedRectangle(cornerRadius: 5))
                }.padding(.horizontal, 10).frame(height: 34).background(LibraryTheme.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            } else { recordButton(big: false) }
        }
    }
    private func row(_ meeting: LibraryMeeting) -> some View {
        let selected = store.selectedKey == meeting.libraryKey
        let dim = selected ? Color.white.opacity(0.86) : LibraryTheme.dim
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(meeting.title ?? UXText.text("library.untitled")).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 2)
                if let start = meeting.start { Text(store.format.rowTime(start)).font(.system(size: 11.5)).foregroundStyle(dim).monospacedDigit() }
            }
            HStack(spacing: 6) {
                if let badge = meeting.state.badge { badgePill(badge, selected: selected) }
                if meeting.state.lifecycle != .recording && ![.queued, .running].contains(meeting.state.transcript) {
                    Text(LibraryFormat.rowMeta(durationMs: meeting.durationMs, names: meeting.speakerNames)).foregroundStyle(dim).lineLimit(1)
                }
            }.font(.system(size: 11.5))
            if [.queued, .running].contains(meeting.state.transcript), let duration = meeting.durationMs {
                Text(UXText.text("library.row.transcribing.line", ["duration": LibraryFormat.meetingDuration(duration)])).font(.system(size: 11.5)).foregroundStyle(dim).lineLimit(1)
            } else if let quote = meeting.quote { Text(quote.displayText).font(.system(size: 11.5)).foregroundStyle(dim).lineLimit(1) }
        }
        .foregroundStyle(selected ? .white : Color(nsColor: .labelColor))
        .padding(.vertical, 1).frame(minHeight: 50, alignment: .top)
    }
    private func badgePill(_ badge: MeetingBadge, selected: Bool) -> some View {
        let tint: Color = badge.tint == "red" ? LibraryTheme.red : badge.tint == "amber" ? Color(red: 122/255, green: 77/255, blue: 0) : badge.tint == "accent" ? .accentColor : LibraryTheme.dim
        return HStack(spacing: 4) {
            if badge.dot == true { Circle().fill(selected ? .white : tint).frame(width: 5, height: 5) }
            Text(badge.text).fontWeight(.semibold)
        }.padding(.horizontal, 7).padding(.vertical, 1)
            .foregroundStyle(selected ? .white : tint)
            .background((selected ? Color.white.opacity(0.22) : tint.opacity(0.10)), in: Capsule())
    }
    private func preview(_ meeting: LibraryMeeting) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(meeting.title ?? UXText.text("library.untitled")).font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
                if let start = meeting.start { Text(store.format.previewSubtitle(start, durationMs: meeting.durationMs, received: meeting.state.origin == .received)).foregroundStyle(LibraryTheme.dim) }
            }
            HStack(spacing: 8) {
                ForEach(meeting.speakers, id: \.id) { speaker in
                    HStack(spacing: 6) {
                        Text(speaker.displayName)
                        if speaker.provenance == .recognised { autoTag }
                    }.padding(.horizontal, 12).frame(height: 28).background(LibraryTheme.chip, in: Capsule())
                }
            }
            HStack(spacing: 10) {
                Button { play(meeting) } label: { Label(UXText.text("common.play"), systemImage: "play.fill").frame(height: 24) }
                    .buttonStyle(.borderedProminent).disabled(meeting.state.origin == .own || meeting.audioFiles.isEmpty)
                    .accessibilityIdentifier("preview-play")
                Button(UXText.text("library.preview.readTranscript")) { readTranscript(meeting) }
                    .buttonStyle(.bordered).controlSize(.large).disabled(meeting.transcriptItems.isEmpty)
                    .accessibilityIdentifier("preview-read-transcript")
            }
            VStack(alignment: .leading, spacing: 16) {
                Divider()
                Text(UXText.text("library.preview.transcriptHeading")).font(.system(size: 11.5, weight: .bold)).foregroundStyle(LibraryTheme.dim).padding(.top, 4)
                ForEach(Array(store.excerpt(meeting).enumerated()), id: \.offset) { _, turn in
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(meeting.speakers.first { $0.id == turn.speaker }?.displayName ?? UXText.text("common.speaker.unnamed", ["n": "1"])).fontWeight(.semibold)
                                if meeting.speakers.first(where: { $0.id == turn.speaker })?.provenance == .recognised { autoTag }
                            }
                            Text(LibraryFormat.position(turn.startMs)).font(.system(size: 11.5)).foregroundStyle(LibraryTheme.dim).monospacedDigit()
                        }.frame(width: 110, alignment: .leading)
                        Text(turn.text).lineSpacing(4).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 44).padding(.vertical, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
            .accessibilityLabel(UXText.text("library.previewPane.a11y"))
    }
    private var autoTag: some View {
        Text(UXText.text("common.autoTag")).font(.system(size: 10, weight: .medium)).foregroundStyle(LibraryTheme.dim)
            .padding(.horizontal, 4).overlay(RoundedRectangle(cornerRadius: 4).stroke(LibraryTheme.dim.opacity(0.3)))
            .help(UXText.text("common.autoTag.tooltip"))
    }
    private var firstRun: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 22) {
                Image(systemName: "mic").font(.system(size: 36, weight: .light)).foregroundStyle(LibraryTheme.dim)
                    .frame(width: 96, height: 96).background(LibraryTheme.chip, in: Circle()).accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(UXText.text("firstRun.title")).font(.system(size: 22, weight: .bold)).fixedSize(horizontal: true, vertical: false)
                    Text(UXText.text("firstRun.body")).foregroundStyle(LibraryTheme.dim).lineSpacing(4).multilineTextAlignment(.center).frame(maxWidth: 460)
                }
                recordButton(big: true)
                Text(UXText.text("firstRun.shortcutHint", ["shortcut": UXText.text("common.shortcut.record")])).font(.system(size: 11.5)).foregroundStyle(LibraryTheme.dim)
            }
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "lock").accessibilityHidden(true)
                Text(UXText.text("firstRun.footer"))
            }.font(.system(size: 11.5)).foregroundStyle(LibraryTheme.dim).padding(16)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
    }
    private func recordButton(big: Bool) -> some View {
        Button { openWindow(id: "recording") } label: {
            HStack(spacing: big ? 10 : 8) {
                Circle().fill(big ? Color.white : LibraryTheme.red).frame(width: big ? 12 : 10, height: big ? 12 : 10)
                Text(UXText.text("common.record")).fontWeight(.semibold)
            }.padding(.horizontal, big ? 22 : 14).frame(height: big ? 44 : 34)
                .foregroundStyle(big ? .white : Color(nsColor: .labelColor))
                .background(big ? LibraryTheme.red : LibraryTheme.chip, in: RoundedRectangle(cornerRadius: big ? 22 : 6))
        }.buttonStyle(.plain).accessibilityIdentifier(big ? "first-run-record" : "toolbar-record")
    }
    private func play(_ meeting: LibraryMeeting) {
        guard let audio = meeting.audioFiles.first, meeting.state.origin == .received else { return }
        openWindow(id: "legacy-viewer", value: LegacyRoute(url: audio, autoplay: true))
    }
    private func readTranscript(_ meeting: LibraryMeeting) {
        if meeting.state.origin == .received, let url = meeting.audioFiles.first { openWindow(id: "legacy-viewer", value: LegacyRoute(url: url, autoplay: false)) }
        else { LegacyOpening.openTranscript(meeting) }
    }
}
