// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// L-32 (D-1011): macOS 26 soft top scroll-edge chrome for sidebar lists, search results,
/// and the meeting/recording panes, with zero drawn permanent header hairlines on older macOS.
enum ScrollEdgeChrome {
    @MainActor
    static func configureUnifiedWindow(_ window: NSWindow) {
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
    }

    @MainActor
    static func suppressTitlebarHairline(_ window: NSWindow?) {
        window?.titlebarSeparatorStyle = .none
    }
}

#if DEBUG
private struct ForceLegacyScrollEdgeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var cassiniForceLegacyScrollEdge: Bool {
        get { self[ForceLegacyScrollEdgeKey.self] }
        set { self[ForceLegacyScrollEdgeKey.self] = newValue }
    }
}
#endif

#if compiler(>=6.2)
private struct CassiniTopScrollEdgeState: Equatable {
    var scrolled = false
    var topInset: CGFloat = 0
}
#endif

private struct CassiniTopScrollEdgeModifier: ViewModifier {
    var pinnedHeaderActive = false
    var pinnedHeaderHeight: CGFloat = 44
    var headerApproaching = false
    #if compiler(>=6.2)
    @State private var edgeState = CassiniTopScrollEdgeState()
    #if DEBUG
    @Environment(\.cassiniForceLegacyScrollEdge) private var forceLegacy
    #endif

    private var usesLegacyFallback: Bool {
        #if DEBUG
        forceLegacy
        #else
        false
        #endif
    }
    #endif

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), !usesLegacyFallback {
            content
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectHidden(pinnedHeaderActive || headerApproaching, for: .top)
                .onScrollGeometryChange(for: CassiniTopScrollEdgeState.self) { geometry in
                    CassiniTopScrollEdgeState(
                        scrolled: geometry.contentOffset.y + geometry.contentInsets.top > 0.5,
                        topInset: max(0, geometry.contentInsets.top)
                    )
                } action: { _, updated in
                    edgeState = updated
                }
                .mask {
                    GeometryReader { proxy in
                        let height = max(1, proxy.size.height)
                        if edgeState.scrolled {
                            let headerEnd = min(height, edgeState.topInset + pinnedHeaderHeight)
                            let clearEnd = pinnedHeaderActive ? headerEnd : max(0, edgeState.topInset - 8)
                            let fadeEnd = min(height, pinnedHeaderActive ? headerEnd + 20 : edgeState.topInset + 20)
                            if pinnedHeaderActive {
                                // The controls stay opaque; only the transcript beneath them fades.
                                VStack(spacing: 0) {
                                    Color.clear.frame(height: edgeState.topInset)
                                    Rectangle().frame(height: max(0, headerEnd - edgeState.topInset))
                                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                        .frame(height: max(0, fadeEnd - headerEnd))
                                    Rectangle()
                                }
                            } else if headerApproaching {
                                // Keep the approaching controls opaque without exposing content in the toolbar.
                                VStack(spacing: 0) {
                                    Color.clear.frame(height: edgeState.topInset)
                                    Rectangle()
                                }
                            } else {
                                LinearGradient(
                                    stops: [
                                        .init(color: CassiniTheme.ink.opacity(0), location: 0),
                                        .init(color: CassiniTheme.ink.opacity(0), location: clearEnd / height),
                                        .init(color: CassiniTheme.ink, location: fadeEnd / height),
                                        .init(color: CassiniTheme.ink, location: 1),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            }
                        } else {
                            Rectangle()
                        }
                    }
                    .ignoresSafeArea(edges: .top)
                }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
private struct ToolbarChromeWindowBridge: NSViewRepresentable {
    let transparentTitlebar: Bool

    final class ProbeView: NSView {
        var transparentTitlebar = false {
            didSet { apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            window?.titlebarAppearsTransparent = transparentTitlebar
        }
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.transparentTitlebar = transparentTitlebar
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.transparentTitlebar = transparentTitlebar
    }
}
#endif

private struct CassiniUnifiedToolbarChromeModifier: ViewModifier {
    #if compiler(>=6.2)
    #if DEBUG
    @Environment(\.cassiniForceLegacyScrollEdge) private var forceLegacy
    #endif

    private var usesLegacyFallback: Bool {
        #if DEBUG
        forceLegacy
        #else
        false
        #endif
    }
    #endif

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), !usesLegacyFallback {
            // Suppress AppKit's ThinFilmPocket / NSScrollPocket permanent 1px toolbar separator
            // at rest on macOS 26+; each pane applies its own soft top scroll-edge fade via cassiniTopScrollEdge().
            content
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .background(ToolbarChromeWindowBridge(transparentTitlebar: true))
        } else if #available(macOS 26.0, *) {
            content
                .background(ToolbarChromeWindowBridge(transparentTitlebar: false))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct CassiniSidebarBackgroundModifier: ViewModifier {
    #if compiler(>=6.2)
    #if DEBUG
    @Environment(\.cassiniForceLegacyScrollEdge) private var forceLegacy
    #endif

    private var usesLegacyFallback: Bool {
        #if DEBUG
        forceLegacy
        #else
        false
        #endif
    }
    #endif

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), !usesLegacyFallback {
            content.background(alignment: .bottom) {
                GeometryReader { proxy in
                    NativeSidebarMaterial()
                        .frame(width: proxy.size.width, height: proxy.size.height + 100)
                        .offset(y: -100)
                }
            }
        } else {
            content.background(NativeSidebarMaterial())
        }
        #else
        content.background(NativeSidebarMaterial())
        #endif
    }
}

struct CassiniColumnDivider: View {
    #if compiler(>=6.2)
    #if DEBUG
    @Environment(\.cassiniForceLegacyScrollEdge) private var forceLegacy
    #endif

    private var usesLegacyFallback: Bool {
        #if DEBUG
        forceLegacy
        #else
        false
        #endif
    }
    #endif

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), !usesLegacyFallback {
            Divider()
                .background(alignment: .bottom) {
                    GeometryReader { proxy in
                        CassiniTheme.cardStroke
                            .frame(width: 1, height: proxy.size.height + 100)
                            .offset(y: -100)
                    }
                }
        } else {
            Divider()
        }
        #else
        Divider()
        #endif
    }
}

private struct CassiniPinnedTopBarModifier<Bar: View>: ViewModifier {
    let alignment: HorizontalAlignment
    let bar: () -> Bar

    func body(content: Content) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            bar()
            content
        }
    }
}

extension View {
    /// Applies the macOS 26 soft top scroll-edge effect when available; no-op on macOS <26.
    func cassiniTopScrollEdge(pinnedHeaderActive: Bool = false, pinnedHeaderHeight: CGFloat = 44, headerApproaching: Bool = false) -> some View {
        modifier(CassiniTopScrollEdgeModifier(pinnedHeaderActive: pinnedHeaderActive, pinnedHeaderHeight: pinnedHeaderHeight, headerApproaching: headerApproaching))
    }

    /// Suppresses the unified window toolbar's permanent thin-film separator on macOS 26+ while
    /// keeping Sequoia's titlebar backdrop intact on macOS <26.
    func cassiniUnifiedToolbarChrome() -> some View {
        modifier(CassiniUnifiedToolbarChromeModifier())
    }

    /// Applies `NativeSidebarMaterial`, extending cleanly behind the unified toolbar on macOS 26+
    /// without bleeding below the pane's bottom edge.
    func cassiniSidebarBackground() -> some View {
        modifier(CassiniSidebarBackgroundModifier())
    }

    /// Pins a header bar above a scrolling pane with zero permanent hairline at rest, preserving
    /// main-tree accessibility hit testing across macOS 15 and macOS 26+.
    func cassiniPinnedTopBar<Bar: View>(
        alignment: HorizontalAlignment = .leading,
        @ViewBuilder bar: @escaping () -> Bar
    ) -> some View {
        modifier(CassiniPinnedTopBarModifier(alignment: alignment, bar: bar))
    }
}

