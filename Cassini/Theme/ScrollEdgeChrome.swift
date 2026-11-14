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
                            let clearEnd = max(0, edgeState.topInset - 8)
                            let fadeEnd = min(height, edgeState.topInset + 20)
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
                        } else {
                            Rectangle()
                        }
                    }
                }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

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
            // Suppress AppKit's ThinFilmPocket permanent 1px toolbar separator at rest on macOS 26+;
            // each pane applies its own soft top scroll-edge fade via cassiniTopScrollEdge().
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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
    func cassiniTopScrollEdge() -> some View {
        modifier(CassiniTopScrollEdgeModifier())
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

#if DEBUG
extension ScrollEdgeChrome {
    @MainActor
    private static func logFailure(_ message: String) {
        FileHandle.standardError.write(Data("ScrollEdgeChrome self-test failed: \(message)\n".utf8))
    }

    @MainActor
    static func nativeSelfTest() -> [String: Bool] {
        var windowConfigured = true
        var legacyClean = true
        var nativeClean = true

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: appearanceName) else {
                return [
                    "scrollEdgeWindowSuppressesTitlebarHairline": false,
                    "scrollEdgeLegacyFallbackHasNoHeaderHairline": false,
                    "scrollEdgeNativeSoftPocketsAndHitTesting": false,
                ]
            }

            let plain = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            plain.isReleasedWhenClosed = false
            plain.appearance = appearance
            plain.toolbar = NSToolbar(identifier: "cassini-scroll-edge-plain-\(appearanceName.rawValue)")
            configureUnifiedWindow(plain)
            plain.layoutIfNeeded()
            if plain.toolbarStyle != .unified || plain.titlebarSeparatorStyle != .none {
                logFailure("plain window toolbarStyle/titlebarSeparatorStyle mismatch")
                windowConfigured = false
            }
            plain.close()

            let legacyDoc = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            legacyDoc.isReleasedWhenClosed = false
            legacyDoc.appearance = appearance
            suppressTitlebarHairline(legacyDoc)
            if legacyDoc.titlebarSeparatorStyle != .none {
                logFailure("legacyDoc titlebarSeparatorStyle != .none")
                windowConfigured = false
            }
            legacyDoc.close()

            if !verifySurfaces(appearance: appearance, forceLegacy: true) {
                legacyClean = false
            }
            if !verifySurfaces(appearance: appearance, forceLegacy: false) {
                nativeClean = false
            }
        }

        return [
            "scrollEdgeWindowSuppressesTitlebarHairline": windowConfigured,
            "scrollEdgeLegacyFallbackHasNoHeaderHairline": legacyClean,
            "scrollEdgeNativeSoftPocketsAndHitTesting": nativeClean,
        ]
    }

    @MainActor
    private static func collectViews(_ root: NSView) -> [NSView] {
        var all = [root]
        for child in root.subviews {
            all.append(contentsOf: collectViews(child))
        }
        return all
    }

    @MainActor
    private static func hasVisiblePocketSeparatorLayer(in root: NSView, maxMinX: CGFloat) -> Bool {
        func checkLayer(_ layer: CALayer) -> Bool {
            guard !layer.isHidden, layer.opacity > 0.01 else { return false }
            if layer.name == "Separator", layer.bounds.height <= 2, layer.bounds.width >= 40 {
                return true
            }
            for sub in layer.sublayers ?? [] where checkLayer(sub) {
                return true
            }
            return false
        }

        for view in collectViews(root) where NSStringFromClass(type(of: view)) == "NSScrollPocket" {
            let rect = view.convert(view.bounds, to: nil)
            if rect.minX < maxMinX, !view.isHidden, view.alphaValue > 0.01, let layer = view.layer, checkLayer(layer) {
                return true
            }
        }
        return false
    }

    @MainActor
    private static func verifySurfaces(appearance: NSAppearance, forceLegacy: Bool) -> Bool {
        let colorScheme: ColorScheme = appearance.name == .darkAqua ? .dark : .light
        let tag = "\(appearance.name.rawValue)-legacy=\(forceLegacy)"

        // 1a. Library split at rest (.idle): verify zero 1px hairline below search bar and active scroll fade.
        var query = ""
        func makeLibrarySplit(dropState: LibraryDropState) -> some View {
            GeometryReader { _ in
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ZStack {
                            List(0..<18, id: \.self) { index in
                                Text("Meeting \(index)")
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                            .listStyle(.sidebar)
                            .scrollContentBackground(.hidden)
                            .cassiniTopScrollEdge()

                            LibraryDropListOverlay(state: dropState)
                        }
                        .cassiniPinnedTopBar {
                            LibrarySearchField(
                                text: Binding(get: { query }, set: { query = $0 }),
                                large: false,
                                onChange: {},
                                onCancel: {}
                            )
                            .frame(height: 28)
                            .padding(.horizontal, 10)
                            .padding(.top, 6)
                            .padding(.bottom, 8)
                        }

                        LibraryDropHintFooter(entered: dropState.showsWindowOutline)
                    }
                    .cassiniSidebarBackground()
                    .frame(minWidth: 400, maxWidth: 400)

                    CassiniColumnDivider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(0..<20, id: \.self) { index in
                                CassiniTheme.ink.opacity(0.22)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 30)
                            }
                        }
                    }
                    .cassiniTopScrollEdge()
                    .background(CassiniTheme.paneGround)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .environment(\.colorScheme, colorScheme)
            .environment(\.cassiniForceLegacyScrollEdge, forceLegacy)
        }

        guard checkWindow(
            label: "lib-idle-\(tag)",
            appearance: appearance,
            rootView: makeLibrarySplit(dropState: .idle),
            expectsSearchFieldMinWidth: 360,
            checkHeaderHairlineSpike: true,
            expectNativeScrollFadeOnMacOS26: !forceLegacy,
            leftPaneWidth: 400,
            rightSampleX: 600
        ) else {
            return false
        }

        // 1b. Library split with .enteredWindow drop overlay: verify search field stays hit-testable and focusable.
        guard checkWindow(
            label: "lib-drop-\(tag)",
            appearance: appearance,
            rootView: makeLibrarySplit(dropState: .enteredWindow),
            expectsSearchFieldMinWidth: 360,
            checkHeaderHairlineSpike: false,
            expectNativeScrollFadeOnMacOS26: !forceLegacy,
            leftPaneWidth: 400,
            rightSampleX: 600
        ) else {
            return false
        }

        // 2. Search split surface (results ScrollView + pinned search header + context ScrollView)
        let searchSplit = HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<20, id: \.self) { index in
                        Text("Hit \(index)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 4)
            }
            .cassiniTopScrollEdge()
            .cassiniPinnedTopBar(alignment: .leading) {
                VStack(alignment: .leading, spacing: 0) {
                    LibrarySearchField(
                        text: Binding(get: { query }, set: { query = $0 }),
                        large: false,
                        onChange: {},
                        onCancel: {}
                    )
                    .frame(height: 28)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 8)

                    Text("4 places in 3 meetings")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CassiniTheme.ink2)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 460)
            .cassiniSidebarBackground()

            CassiniColumnDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<20, id: \.self) { _ in
                        CassiniTheme.ink.opacity(0.22)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                    }
                }
            }
            .cassiniTopScrollEdge()
            .background(CassiniTheme.paneGround)
        }
        .environment(\.colorScheme, colorScheme)
        .environment(\.cassiniForceLegacyScrollEdge, forceLegacy)

        guard checkWindow(
            label: "search-\(tag)",
            appearance: appearance,
            rootView: searchSplit,
            expectsSearchFieldMinWidth: 420,
            checkHeaderHairlineSpike: true,
            expectNativeScrollFadeOnMacOS26: !forceLegacy,
            leftPaneWidth: 460,
            rightSampleX: 700
        ) else {
            return false
        }

        // 3. Meeting split surface (speakers ScrollView + pinned heading + transcript ScrollView)
        let meetingSplit = VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(0..<18, id: \.self) { index in
                                Text("Speaker \(index)")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                            }
                        }
                    }
                    .cassiniTopScrollEdge()
                    .cassiniPinnedTopBar(alignment: .leading) {
                        Text(UXText.text("common.speakers"))
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(CassiniTheme.secondaryInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 19)
                            .padding(.top, 14)
                            .padding(.bottom, 18)
                    }

                    Button(UXText.text("meeting.nameSpeakers")) {}
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 19)
                        .padding(.vertical, 18)
                }
                .frame(width: 260)
                .frame(maxHeight: .infinity)
                .cassiniSidebarBackground()

                CassiniColumnDivider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<20, id: \.self) { _ in
                            CassiniTheme.ink.opacity(0.22)
                                .frame(maxWidth: .infinity)
                                .frame(height: 30)
                        }
                    }
                }
                .cassiniTopScrollEdge()
            }
            Divider()
            CassiniTheme.windowGround.frame(height: 64)
        }
        .background(CassiniTheme.paneGround)
        .environment(\.colorScheme, colorScheme)
        .environment(\.cassiniForceLegacyScrollEdge, forceLegacy)

        guard checkWindow(
            label: "meeting-\(tag)",
            appearance: appearance,
            rootView: meetingSplit,
            expectsSearchFieldMinWidth: nil,
            checkHeaderHairlineSpike: true,
            expectNativeScrollFadeOnMacOS26: !forceLegacy,
            leftPaneWidth: 260,
            rightSampleX: 550
        ) else {
            return false
        }

        // 4. Recording page surface (with NavigationSplitView soft pocket check on macOS 26+)
        let recordingPage = NavigationSplitView {
            List(0..<12, id: \.self) { index in
                Text("Speaker \(index)")
            }
            .cassiniTopScrollEdge()
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<20, id: \.self) { _ in
                        CassiniTheme.ink.opacity(0.22)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                    }
                }
            }
            .cassiniTopScrollEdge()
            .background(CassiniTheme.paneGround)
        }
        .environment(\.colorScheme, colorScheme)
        .environment(\.cassiniForceLegacyScrollEdge, forceLegacy)

        return checkWindow(
            label: "recording-nav-\(tag)",
            appearance: appearance,
            rootView: recordingPage,
            expectsSearchFieldMinWidth: nil,
            checkHeaderHairlineSpike: false,
            expectNativeScrollFadeOnMacOS26: !forceLegacy,
            leftPaneWidth: 260,
            rightSampleX: 600,
            hasPinnedLeftHeader: false,
            verifyNavigationSidebarSoftPocket: !forceLegacy
        )
    }

    @MainActor
    private static func checkWindow<Content: View>(
        label: String,
        appearance: NSAppearance,
        rootView: Content,
        expectsSearchFieldMinWidth: CGFloat?,
        checkHeaderHairlineSpike: Bool,
        expectNativeScrollFadeOnMacOS26: Bool,
        leftPaneWidth: CGFloat,
        rightSampleX: Int,
        hasPinnedLeftHeader: Bool = true,
        verifyNavigationSidebarSoftPocket: Bool = false
    ) -> Bool {
        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1120, height: 720))
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        suppressTitlebarHairline(window)
        window.titleVisibility = .hidden
        defer { window.close() }

        window.layoutIfNeeded()
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        RunLoop.current.run(mode: .default, before: .distantPast)
        window.layoutIfNeeded()
        window.contentView?.superview?.layoutSubtreeIfNeeded()

        guard window.titlebarSeparatorStyle == .none,
              let themeFrame = window.contentView?.superview else {
            logFailure("\(label): missing themeFrame or titlebarSeparatorStyle != .none")
            return false
        }

        let allViews = collectViews(themeFrame)
        let windowHeight = themeFrame.bounds.height

        // 1. Verify no AppKit horizontal separator view or visible pocket Separator layer in the pinned-header pane.
        if hasPinnedLeftHeader && hasVisiblePocketSeparatorLayer(in: themeFrame, maxMinX: leftPaneWidth) {
            logFailure("\(label): visible NSScrollPocket Separator layer at rest in left pane")
            return false
        }
        for view in allViews where !view.isHidden && view.alphaValue > 0.01 {
            let className = NSStringFromClass(type(of: view))
            if className.contains("TitlebarSeparator") {
                let rect = view.convert(view.bounds, to: nil)
                if rect.height > 0 && rect.width > 40 {
                    logFailure("\(label): visible TitlebarSeparator \(rect)")
                    return false
                }
            }
            if view is NSBox || className.contains("Separator") {
                let rect = view.convert(view.bounds, to: nil)
                let inTopHeaderZone = rect.minY > windowHeight - 160
                let spansHeaderHorizontally = rect.width >= min(leftPaneWidth - 40, 180) && rect.height <= 2
                if inTopHeaderZone && spansHeaderHorizontally {
                    logFailure("\(label): horizontal separator view \(className) at \(rect)")
                    return false
                }
            }
        }

        // 2. Verify left pinned-header scroll view has zero 1px separator spike at rest.
        let leftScrollViews = allViews.compactMap { $0 as? NSScrollView }.filter {
            let r = $0.convert($0.bounds, to: nil)
            return r.minX < leftPaneWidth && r.height > 100
        }
        if checkHeaderHairlineSpike, let leftScroll = leftScrollViews.first {
            guard let bitmap = renderBitmap(of: themeFrame) else {
                logFailure("\(label): renderBitmap failed")
                return false
            }
            let scrollRect = leftScroll.convert(leftScroll.bounds, to: nil)
            let boundaryY = Int((windowHeight - scrollRect.maxY).rounded())
            let sampleX = Int(min(leftPaneWidth - 20, max(20, leftPaneWidth - 28)))
            if hasOnePixelSeparatorSpike(in: bitmap, x: sampleX, aroundY: boundaryY, radius: 3) {
                logFailure("\(label): 1px hairline spike at x=\(sampleX) around y=\(boundaryY)")
                return false
            }
        }

        // 3. Verify search field width, hit-testing (not blocked by drop overlay), and focus.
        if let minWidth = expectsSearchFieldMinWidth {
            guard let searchField = allViews.compactMap({ $0 as? NSSearchField }).first else {
                logFailure("\(label): missing NSSearchField")
                return false
            }
            let rectInWindow = searchField.convert(searchField.bounds, to: nil)
            guard rectInWindow.width >= minWidth else {
                logFailure("\(label): searchField width \(rectInWindow.width) < \(minWidth)")
                return false
            }
            let midInSuper = themeFrame.convert(NSPoint(x: rectInWindow.midX, y: rectInWindow.midY), from: nil)
            guard let hitView = themeFrame.hitTest(midInSuper),
                  hitView === searchField || hitView.isDescendant(of: searchField) else {
                logFailure("\(label): searchField hitTest failed")
                return false
            }
            guard window.makeFirstResponder(searchField) else {
                logFailure("\(label): makeFirstResponder(searchField) failed")
                return false
            }
            guard let leftScroll = leftScrollViews.first else {
                logFailure("\(label): missing left NSScrollView")
                return false
            }
            let scrollRect = leftScroll.convert(leftScroll.bounds, to: nil)
            guard scrollRect.maxY <= rectInWindow.minY + 1 else {
                logFailure("\(label): leftScroll maxY \(scrollRect.maxY) overlaps searchField minY \(rectInWindow.minY)")
                return false
            }
        }

        // 4. Verify scroll behavior on macOS 26+: soft top fade activates when scrolled, while legacy fallback stays unmasked.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if verifyNavigationSidebarSoftPocket {
                let pockets = allViews.filter { NSStringFromClass(type(of: $0)) == "NSScrollPocket" }
                guard !pockets.isEmpty else {
                    logFailure("\(label): expected NSScrollPocket in NavigationSplitView")
                    return false
                }
                for pocket in pockets {
                    guard let style = pocket.value(forKey: "style") as? Int, style == 1 else {
                        logFailure("\(label): NSScrollPocket style != .soft (1)")
                        return false
                    }
                }
            }

            let scrollViews = allViews.compactMap { $0 as? NSScrollView }.filter { $0.bounds.height > 120 }
            for sv in scrollViews {
                sv.contentView.scroll(to: NSPoint(x: 0, y: 120))
                sv.reflectScrolledClipView(sv.contentView)
            }
            window.layoutIfNeeded()
            themeFrame.layoutSubtreeIfNeeded()
            RunLoop.current.run(mode: .default, before: .distantPast)
            window.layoutIfNeeded()
            themeFrame.layoutSubtreeIfNeeded()

            guard let rightScroll = scrollViews.first(where: {
                let r = $0.convert($0.bounds, to: nil)
                return r.minX <= CGFloat(rightSampleX) && r.maxX >= CGFloat(rightSampleX)
            }), let scrolledBitmap = renderBitmap(of: themeFrame) else {
                logFailure("\(label): missing rightScroll or scrolledBitmap")
                return false
            }
            let rightRect = rightScroll.convert(rightScroll.bounds, to: nil)
            let topEdgeY = Int((windowHeight - rightRect.maxY).rounded()) + Int(rightScroll.contentInsets.top.rounded())
            let nearTopLuma = luminance(in: scrolledBitmap, x: rightSampleX, y: max(1, topEdgeY + 2))
            let midPaneLuma = luminance(in: scrolledBitmap, x: rightSampleX, y: min(Int(windowHeight) - 2, topEdgeY + 45))
            if expectNativeScrollFadeOnMacOS26 {
                if abs(nearTopLuma - midPaneLuma) < 0.02 {
                    logFailure("\(label): expected soft fade luma delta >= 0.02, got near=\(nearTopLuma) mid=\(midPaneLuma) topEdgeY=\(topEdgeY)")
                    return false
                }
            } else {
                if abs(nearTopLuma - midPaneLuma) > 0.01 {
                    logFailure("\(label): expected unmasked legacy luma delta <= 0.01, got near=\(nearTopLuma) mid=\(midPaneLuma)")
                    return false
                }
            }
        }
        #endif

        return true
    }

    @MainActor
    private static func renderBitmap(of view: NSView) -> NSBitmapImageRep? {
        let width = Int(view.bounds.width.rounded())
        let height = Int(view.bounds.height.rounded())
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: width,
                  pixelsHigh: height,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ) else {
            return nil
        }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private static func luminance(in rep: NSBitmapImageRep, x: Int, y: Int) -> Double {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * Double(color.redComponent)
            + 0.7152 * Double(color.greenComponent)
            + 0.0722 * Double(color.blueComponent)
    }

    private static func hasOnePixelSeparatorSpike(in rep: NSBitmapImageRep, x: Int, aroundY: Int, radius: Int) -> Bool {
        let minY = max(2, aroundY - radius)
        let maxY = min(rep.pixelsHigh - 3, aroundY + radius)
        guard minY <= maxY else { return false }
        for y in minY...maxY {
            let prev = luminance(in: rep, x: x, y: y - 1)
            let curr = luminance(in: rep, x: x, y: y)
            let next = luminance(in: rep, x: x, y: y + 1)
            let darkerSpike = (prev - curr > 0.015) && (next - curr > 0.015)
            let lighterSpike = (curr - prev > 0.015) && (curr - next > 0.015)
            if darkerSpike || lighterSpike {
                return true
            }
        }
        return false
    }
}
#endif
