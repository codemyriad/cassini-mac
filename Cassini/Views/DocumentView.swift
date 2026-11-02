// SPDX-License-Identifier: GPL-3.0-or-later
import CassiniKit
import SwiftUI

/// One document window: sidebar, content column with the player bar, and the inspector.
struct DocumentView: View {
    @State private var session: SessionModel
    @FocusState private var searchFocused: Bool
    private let autoPlay: Bool

    init(document: CassiniDocument, fileURL: URL?, autoPlay: Bool = false) {
        self.autoPlay = autoPlay
        _session = State(initialValue: SessionModel(document: document, url: fileURL))
    }

    init(session: SessionModel) {
        autoPlay = false
        _session = State(initialValue: session)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(session: session)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            ContentColumn(session: session)
        }
        .inspector(isPresented: $session.showInspector) {
            InspectorView(session: session)
                .inspectorColumnWidth(min: 240, ideal: 260, max: 360)
        }
        .navigationTitle(session.title)
        .navigationSubtitle(session.subtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if session.hasSummary {
                    Picker("View", selection: $session.tab) {
                        Text(UXText.text("library.preview.transcriptHeading")).tag(SessionModel.Tab.transcript)
                        Text(UXText.text("mac.legacy.summary")).tag(SessionModel.Tab.summary)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    session.showInspector.toggle()
                } label: {
                    Label(UXText.text("mac.legacy.toggleInfo"), systemImage: "info.circle")
                }
                .help(UXText.text("mac.legacy.toggleInfo"))
            }
        }
        .searchable(text: $session.searchText, placement: .toolbar, prompt: Text(UXText.text("search.title")))
        .searchFocused($searchFocused)
        .onChange(of: session.focusSearchRequest) { searchFocused = true }
        .focusedSceneValue(\.session, session)
        .background(WindowAccessor { window in session.window = window })
        .onAppear { if autoPlay { session.player?.play() } }
        .onDisappear { session.close() }
        .frame(minWidth: 760, minHeight: 480)
    }
}

/// The middle column: the transcript or the summary, with the player bar pinned below.
struct ContentColumn: View {
    @Bindable var session: SessionModel

    var body: some View {
        Group {
            if session.tab == .summary, let md = session.manifest?.summaryMarkdown {
                SummaryView(markdown: md, session: session)
            } else if session.timeline != nil {
                VStack(spacing: 0) {
                    if session.hasQuery {
                        SearchStatusBar(session: session)
                        Divider()
                    }
                    TranscriptView(session: session)
                        .overlay(alignment: .bottomTrailing) {
                            if session.follow && session.followPaused {
                                Button {
                                    session.jumpToCurrent()
                                } label: {
                                    Label(UXText.text("mac.legacy.jumpToCurrent"), systemImage: "arrow.down.to.line")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .padding(16)
                                .transition(.opacity)
                            }
                        }
                }
            } else {
                NoTranscriptView(session: session)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let player = session.player {
                PlayerBar(session: session, player: player)
            }
        }
    }
}

struct SearchStatusBar: View {
    @Bindable var session: SessionModel

    var body: some View {
        HStack(spacing: 8) {
            Text(matchText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button(UXText.text("mac.legacy.previousMatch"), systemImage: "chevron.up") { session.findPrevious() }
                .labelStyle(.iconOnly)
                .disabled(session.matchCount == 0)
            Button(UXText.text("mac.legacy.nextMatch"), systemImage: "chevron.down") { session.findNext() }
                .labelStyle(.iconOnly)
                .disabled(session.matchCount == 0)
            Button(UXText.text("common.done")) { session.searchText = "" }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private var matchText: String {
        let q = session.searchText.trimmingCharacters(in: .whitespaces)
        switch session.matchCount {
        case 0: return "No matches for “\(q)”"
        case 1: return "1 match for “\(q)”"
        default: return "\(session.matchIndex) of \(session.matchCount) matches for “\(q)”"
        }
    }
}

struct NoTranscriptView: View {
    let session: SessionModel

    var body: some View {
        ContentUnavailableView {
            Label(headline, systemImage: icon)
        } description: {
            Text(session.transcriptProblem ?? "")
        }
    }

    private var headline: String {
        switch session.file?.state {
        case .plainAudio?: return "No transcript in this file"
        case .invalidCassiniMetadata?: return "Transcript unreadable"
        case .unknownCassiniFormat?: return "Newer Cassini format"
        case nil: return "Can’t read this file"
        default: return "Transcript unavailable"
        }
    }

    private var icon: String {
        switch session.file?.state {
        case .plainAudio?: return "waveform"
        case nil, .invalidCassiniMetadata?: return "exclamationmark.triangle"
        default: return "doc.questionmark"
        }
    }
}

/// Hands the hosting window to the model, so window-level events can find it.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}
