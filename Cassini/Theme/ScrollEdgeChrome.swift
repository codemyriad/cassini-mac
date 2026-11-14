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
private enum SelfTestToolbarMode {
    case library
    case search
    case meeting
    case recording
}

private struct SelfTestUnifiedToolbarModifier: ViewModifier {
    let mode: SelfTestToolbarMode
    let applyProductionChrome: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let populated = content
            .navigationTitle(UXText.text("app.name"))
            .toolbar(removing: .title)
            .toolbar { toolbarItems }
        if applyProductionChrome {
            populated.cassiniUnifiedToolbarChrome()
        } else {
            populated
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        switch mode {
        case .library, .search:
            ToolbarItem(placement: .navigation) {
                libraryHeader(isSearch: mode == .search)
            }
        case .meeting:
            ToolbarItem(placement: .navigation) {
                LibraryToolbarAction(
                    title: "",
                    label: UXText.text("common.backToLibrary"),
                    identifier: "selftest-meeting-back",
                    style: .back
                ) {}
            }
            ToolbarItem(placement: .navigation) {
                LibraryToolbarAction(
                    title: UXText.text("common.record"),
                    label: UXText.text("common.record"),
                    identifier: "selftest-toolbar-record",
                    style: .record,
                    enabled: true
                ) {}
            }
            ToolbarItem(placement: .navigation) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Client call, Rossi & Partners")
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    Text("Today, 11:00 · 42 min")
                        .font(.system(size: 11.5))
                        .foregroundStyle(CassiniTheme.secondaryInk)
                        .lineLimit(1)
                }
                .padding(.leading, 44)
                .frame(width: 420, alignment: .leading)
            }
            ToolbarItem(placement: .primaryAction) {
                LibraryToolbarAction(
                    title: UXText.text("common.exportEllipsis"),
                    label: UXText.text("common.exportEllipsis"),
                    identifier: "selftest-meeting-export",
                    style: .capsule,
                    enabled: true
                ) {}
            }
            ToolbarItem(placement: .primaryAction) {
                LibraryToolbarAction(
                    title: "",
                    label: UXText.text("meeting.moreActions"),
                    identifier: "selftest-meeting-more",
                    style: .more
                ) {}
            }
        case .recording:
            ToolbarItem(placement: .navigation) {
                Button {} label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 30)
                }
            }
            ToolbarItem(placement: .principal) {
                Text("Weekly sync")
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
            }
        }
    }

    private func libraryHeader(isSearch: Bool) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                LibraryImportHeaderButton(enabled: true) {}
                HStack(spacing: 7) {
                    Circle().fill(CassiniTheme.onRecord).frame(width: 9, height: 9)
                    Text(UXText.text("common.record")).fontWeight(.semibold)
                }
                .padding(.horizontal, 14)
                .frame(minWidth: 90)
                .frame(height: 34)
                .foregroundStyle(CassiniTheme.onRecord)
                .background(CassiniTheme.record, in: Capsule())
            }
            .padding(.trailing, 10)
            .frame(width: isSearch ? 388 : 328, alignment: .trailing)

            Text(UXText.text(isSearch ? "search.title" : "library.title"))
                .font(.system(size: 15, weight: .bold))
        }
    }
}

extension ScrollEdgeChrome {
    static var isNativeMacOS26Available: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        return false
        #else
        return false
        #endif
    }

    static let nativeCoverageKeys: Set<String> = [
        "scrollEdgeNativeUnifiedToolbarChrome",
        "scrollEdgeNativeSoftPocketsAndHitTesting",
    ]

    @MainActor
    private static func logFailure(_ message: String) {
        FileHandle.standardError.write(Data("ScrollEdgeChrome self-test failed: \(message)\n".utf8))
    }

    @MainActor
    static func nativeSelfTest() -> [String: Any] {
        var windowConfigured = true
        var legacyClean = true
        var nativeToolbarClean = true
        var nativeSurfacesClean = true

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: appearanceName) else {
                return [
                    "scrollEdgeNativeMacOS26Available": isNativeMacOS26Available,
                    "scrollEdgeWindowSuppressesTitlebarHairline": false,
                    "scrollEdgeLegacyFallbackHasNoHeaderHairline": false,
                    "scrollEdgeNativeUnifiedToolbarChrome": false,
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
            if isNativeMacOS26Available {
                if !verifyNativeUnifiedToolbarChrome(appearance: appearance) {
                    nativeToolbarClean = false
                }
                if !verifySurfaces(appearance: appearance, forceLegacy: false) {
                    nativeSurfacesClean = false
                }
            } else {
                // On macOS <26 (or Xcode <26 SDK), verify the production no-op path stays hairline-free,
                // while reporting native macOS 26 coverage as skipped rather than passed.
                if !verifySurfaces(appearance: appearance, forceLegacy: false) {
                    legacyClean = false
                }
            }
        }

        return [
            "scrollEdgeNativeMacOS26Available": isNativeMacOS26Available,
            "scrollEdgeWindowSuppressesTitlebarHairline": windowConfigured,
            "scrollEdgeLegacyFallbackHasNoHeaderHairline": legacyClean,
            "scrollEdgeNativeUnifiedToolbarChrome": isNativeMacOS26Available ? nativeToolbarClean : "skipped",
            "scrollEdgeNativeSoftPocketsAndHitTesting": isNativeMacOS26Available ? nativeSurfacesClean : "skipped",
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
    private static func pumpWindowLayout(_ window: NSWindow) {
        for _ in 0..<3 {
            window.layoutIfNeeded()
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            RunLoop.current.run(mode: .default, before: .distantPast)
        }
        window.layoutIfNeeded()
        window.contentView?.superview?.layoutSubtreeIfNeeded()
    }

    @MainActor
    private static func hasVisiblePocketOrToolbarSeparatorLayer(in root: NSView, maxMinX: CGFloat) -> Bool {
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

        for view in collectViews(root) {
            let className = NSStringFromClass(type(of: view))
            let isPocketOrTitlebar = className.contains("Pocket")
                || className.contains("Titlebar")
                || className.contains("Toolbar")
            guard isPocketOrTitlebar, !view.isHidden, view.alphaValue > 0.01 else { continue }
            let rect = view.convert(view.bounds, to: nil)
            if rect.minX < maxMinX, let layer = view.layer, checkLayer(layer) {
                return true
            }
        }
        return false
    }

    private static func maxAdjacentLuminanceStep(in rep: NSBitmapImageRep, x: Int, minY: Int, maxY: Int) -> Double {
        let clampedMin = max(1, minY)
        let clampedMax = min(rep.pixelsHigh - 2, maxY)
        guard clampedMin < clampedMax else { return 0 }
        var maxStep = 0.0
        var prev = luminance(in: rep, x: x, y: clampedMin)
        for y in (clampedMin + 1)...clampedMax {
            let curr = luminance(in: rep, x: x, y: y)
            maxStep = max(maxStep, abs(curr - prev))
            prev = curr
        }
        return maxStep
    }

    @MainActor
    private static func makeScrollableDetailPane() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<40, id: \.self) { _ in
                    CassiniTheme.ink.opacity(0.22)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
            }
            .padding(.top, 28)
        }
        .cassiniTopScrollEdge()
        .background(CassiniTheme.paneGround)
    }

    @MainActor
    private static func verifyNativeUnifiedToolbarChrome(appearance: NSAppearance) -> Bool {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *) else { return false }
        let tag = "native-toolbar-\(appearance.name.rawValue)"

        let meetingRoot = VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(0..<40, id: \.self) { index in
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
                }
                .frame(width: 260)
                .frame(maxHeight: .infinity)
                .cassiniSidebarBackground()

                CassiniColumnDivider()

                makeScrollableDetailPane()
            }
            Divider()
            CassiniTheme.windowGround.frame(height: 64)
        }
        .background(CassiniTheme.paneGround)

        // 1. Mutant controls: omitting cassiniUnifiedToolbarChrome() on populated Library and Meeting
        // unified toolbars must fail the at-rest macOS 26 toolbar-separator-free predicate, proving
        // that restoring the macOS 26 permanent toolbar hairline fails this regression test.
        var query = ""
        let libraryRoot = HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(0..<40, id: \.self) { index in
                    Text("Meeting \(index)")
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .cassiniTopScrollEdge()
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
            }
            .cassiniSidebarBackground()
            .frame(width: 400)

            CassiniColumnDivider()

            makeScrollableDetailPane()
        }

        let unguardedLibraryState = inspectToolbarChromeAtRest(
            label: "\(tag)-library-unguarded",
            appearance: appearance,
            toolbarMode: .library,
            applyUnifiedToolbarChrome: false,
            forceLegacy: false,
            rootView: libraryRoot,
            rightSampleX: 600
        )
        guard unguardedLibraryState == .separatorDetected else {
            logFailure("\(tag): expected unguarded Library unified toolbar without cassiniUnifiedToolbarChrome() to exhibit macOS 26 toolbar pocket/separator at rest, got \(unguardedLibraryState)")
            return false
        }

        let unguardedToolbarState = inspectToolbarChromeAtRest(
            label: "\(tag)-meeting-unguarded",
            appearance: appearance,
            toolbarMode: .meeting,
            applyUnifiedToolbarChrome: false,
            forceLegacy: false,
            rootView: meetingRoot,
            rightSampleX: 600
        )
        guard unguardedToolbarState == .separatorDetected else {
            logFailure("\(tag): expected unguarded Meeting unified toolbar without cassiniUnifiedToolbarChrome() to exhibit macOS 26 toolbar pocket/separator at rest, got \(unguardedToolbarState)")
            return false
        }

        // 2. Production modifier on populated Library & Meeting unified toolbars: verify rendered separator
        // suppression at rest, toolbar item hit-testing, soft scroll fade when scrolled, and return to rest.
        guard checkWindow(
            label: "\(tag)-library-guarded",
            appearance: appearance,
            toolbarMode: .library,
            applyUnifiedToolbarChrome: true,
            forceLegacy: false,
            rootView: libraryRoot,
            expectsSearchFieldMinWidth: 360,
            checkHeaderHairlineSpike: true,
            expectNativeScrollFadeOnMacOS26: true,
            leftPaneWidth: 400,
            rightSampleX: 600
        ) else {
            return false
        }

        guard checkWindow(
            label: "\(tag)-meeting-guarded",
            appearance: appearance,
            toolbarMode: .meeting,
            applyUnifiedToolbarChrome: true,
            forceLegacy: false,
            rootView: meetingRoot,
            expectsSearchFieldMinWidth: nil,
            checkHeaderHairlineSpike: true,
            expectNativeScrollFadeOnMacOS26: true,
            leftPaneWidth: 260,
            rightSampleX: 600,
            verifyToolbarActionHitTesting: true
        ) else {
            return false
        }

        return true
        #else
        return false
        #endif
    }

    #if compiler(>=6.2)
    private enum ToolbarAtRestState {
        case clean
        case separatorDetected
        case setupFailed
    }

    @MainActor
    private static func inspectToolbarChromeAtRest<Content: View>(
        label: String,
        appearance: NSAppearance,
        toolbarMode: SelfTestToolbarMode,
        applyUnifiedToolbarChrome: Bool,
        forceLegacy: Bool,
        rootView: Content,
        rightSampleX: Int
    ) -> ToolbarAtRestState {
        let colorScheme: ColorScheme = appearance.name == .darkAqua ? .dark : .light
        let hostedRoot = rootView
            .modifier(SelfTestUnifiedToolbarModifier(mode: toolbarMode, applyProductionChrome: applyUnifiedToolbarChrome))
            .environment(\.colorScheme, colorScheme)
            .environment(\.cassiniForceLegacyScrollEdge, forceLegacy)

        let controller = NSHostingController(rootView: hostedRoot)
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1120, height: 720))
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        configureUnifiedWindow(window)
        window.titleVisibility = .hidden
        defer { window.close() }

        pumpWindowLayout(window)

        guard window.toolbarStyle == .unified,
              window.titlebarSeparatorStyle == .none,
              let toolbar = window.toolbar,
              !toolbar.items.isEmpty,
              let themeFrame = window.contentView?.superview,
              let bitmap = renderBitmap(of: themeFrame) else {
            logFailure("\(label): failed to materialize populated unified toolbar window")
            return .setupFailed
        }

        let windowHeight = themeFrame.bounds.height
        let toolbarBoundaryY = Int((windowHeight - window.contentLayoutRect.maxY).rounded())
        guard toolbarBoundaryY >= 28 && toolbarBoundaryY <= 90 else {
            logFailure("\(label): unexpected toolbarBoundaryY=\(toolbarBoundaryY)")
            return .setupFailed
        }

        if hasVisiblePocketOrToolbarSeparatorLayer(in: themeFrame, maxMinX: themeFrame.bounds.width) {
            return .separatorDetected
        }
        if hasOnePixelSeparatorSpike(in: bitmap, x: rightSampleX, aroundY: toolbarBoundaryY, radius: 4)
            || hasOnePixelSeparatorSpike(in: bitmap, x: 5, aroundY: toolbarBoundaryY, radius: 4) {
            return .separatorDetected
        }
        let maxRightStep = maxAdjacentLuminanceStep(
            in: bitmap,
            x: rightSampleX,
            minY: toolbarBoundaryY - 4,
            maxY: toolbarBoundaryY + 6
        )
        let maxLeftStep = maxAdjacentLuminanceStep(
            in: bitmap,
            x: 5,
            minY: toolbarBoundaryY - 4,
            maxY: toolbarBoundaryY + 6
        )
        if maxRightStep > 0.012 || maxLeftStep > 0.012 {
            return .separatorDetected
        }
        return .clean
    }
    #endif

    @MainActor
    private static func verifySurfaces(appearance: NSAppearance, forceLegacy: Bool) -> Bool {
        let tag = "\(appearance.name.rawValue)-legacy=\(forceLegacy)"

        // 1a. Library split at rest (.idle): populated unified toolbar + cassiniUnifiedToolbarChrome(),
        // zero 1px hairline at toolbar or below search bar, and active soft scroll fade on macOS 26+.
        var query = ""
        func makeLibrarySplit(dropState: LibraryDropState) -> some View {
            GeometryReader { _ in
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ZStack {
                            List(0..<40, id: \.self) { index in
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

                    makeScrollableDetailPane()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        guard checkWindow(
            label: "lib-idle-\(tag)",
            appearance: appearance,
            toolbarMode: .library,
            applyUnifiedToolbarChrome: true,
            forceLegacy: forceLegacy,
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
            toolbarMode: .library,
            applyUnifiedToolbarChrome: true,
            forceLegacy: forceLegacy,
            rootView: makeLibrarySplit(dropState: .enteredWindow),
            expectsSearchFieldMinWidth: 360,
            checkHeaderHairlineSpike: false,
            expectNativeScrollFadeOnMacOS26: !forceLegacy,
            leftPaneWidth: 400,
            rightSampleX: 600
        ) else {
            return false
        }

        // 2. Search split surface (populated Search unified toolbar + pinned search header + context ScrollView)
        let searchSplit = HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<40, id: \.self) { index in
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

            makeScrollableDetailPane()
        }

        guard checkWindow(
            label: "search-\(tag)",
            appearance: appearance,
            toolbarMode: .search,
            applyUnifiedToolbarChrome: true,
            forceLegacy: forceLegacy,
            rootView: searchSplit,
            expectsSearchFieldMinWidth: 420,
            checkHeaderHairlineSpike: true,
            expectNativeScrollFadeOnMacOS26: !forceLegacy,
            leftPaneWidth: 460,
            rightSampleX: 700
        ) else {
            return false
        }

        // 3. Meeting split surface (populated Meeting unified toolbar + speakers ScrollView + transcript ScrollView)
        let meetingSplit = VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(0..<40, id: \.self) { index in
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

                makeScrollableDetailPane()
            }
            Divider()
            CassiniTheme.windowGround.frame(height: 64)
        }
        .background(CassiniTheme.paneGround)

        guard checkWindow(
            label: "meeting-\(tag)",
            appearance: appearance,
            toolbarMode: .meeting,
            applyUnifiedToolbarChrome: true,
            forceLegacy: forceLegacy,
            rootView: meetingSplit,
            expectsSearchFieldMinWidth: nil,
            checkHeaderHairlineSpike: true,
            expectNativeScrollFadeOnMacOS26: !forceLegacy,
            leftPaneWidth: 260,
            rightSampleX: 550,
            verifyToolbarActionHitTesting: true
        ) else {
            return false
        }

        // 4. Recording page surface (populated Recording unified toolbar + NavigationSplitView soft pocket check)
        let recordingPage = NavigationSplitView {
            List(0..<30, id: \.self) { index in
                Text("Speaker \(index)")
            }
            .cassiniTopScrollEdge()
        } detail: {
            makeScrollableDetailPane()
        }

        return checkWindow(
            label: "recording-nav-\(tag)",
            appearance: appearance,
            toolbarMode: .recording,
            applyUnifiedToolbarChrome: true,
            forceLegacy: forceLegacy,
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
        toolbarMode: SelfTestToolbarMode,
        applyUnifiedToolbarChrome: Bool,
        forceLegacy: Bool,
        rootView: Content,
        expectsSearchFieldMinWidth: CGFloat?,
        checkHeaderHairlineSpike: Bool,
        expectNativeScrollFadeOnMacOS26: Bool,
        leftPaneWidth: CGFloat,
        rightSampleX: Int,
        hasPinnedLeftHeader: Bool = true,
        verifyNavigationSidebarSoftPocket: Bool = false,
        verifyToolbarActionHitTesting: Bool = false
    ) -> Bool {
        let colorScheme: ColorScheme = appearance.name == .darkAqua ? .dark : .light
        let hostedRoot = rootView
            .modifier(SelfTestUnifiedToolbarModifier(mode: toolbarMode, applyProductionChrome: applyUnifiedToolbarChrome))
            .environment(\.colorScheme, colorScheme)
            .environment(\.cassiniForceLegacyScrollEdge, forceLegacy)

        let controller = NSHostingController(rootView: hostedRoot)
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1120, height: 720))
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        configureUnifiedWindow(window)
        window.titleVisibility = .hidden
        defer { window.close() }

        pumpWindowLayout(window)

        guard window.toolbarStyle == .unified,
              window.titlebarSeparatorStyle == .none,
              let toolbar = window.toolbar,
              !toolbar.items.isEmpty,
              let themeFrame = window.contentView?.superview else {
            logFailure("\(label): missing themeFrame, unified style, or populated window.toolbar")
            return false
        }

        let allViews = collectViews(themeFrame)
        let windowHeight = themeFrame.bounds.height
        let toolbarBoundaryY = Int((windowHeight - window.contentLayoutRect.maxY).rounded())
        guard toolbarBoundaryY >= 28 && toolbarBoundaryY <= 90 else {
            logFailure("\(label): unexpected toolbarBoundaryY=\(toolbarBoundaryY)")
            return false
        }

        if verifyToolbarActionHitTesting {
            let toolbarActions = allViews.compactMap { $0 as? LibraryToolbarActionView }.filter { $0.bounds.width > 0 }
            guard toolbarActions.count >= 3 else {
                logFailure("\(label): expected populated LibraryToolbarActionView controls in unified toolbar, found \(toolbarActions.count)")
                return false
            }
            for actionView in toolbarActions {
                let rectInWindow = actionView.convert(actionView.bounds, to: nil)
                guard rectInWindow.minY >= window.contentLayoutRect.maxY - 2 else {
                    logFailure("\(label): toolbar action \(rectInWindow) not in unified toolbar strip above \(window.contentLayoutRect.maxY)")
                    return false
                }
                let midInTheme = themeFrame.convert(NSPoint(x: rectInWindow.midX, y: rectInWindow.midY), from: nil)
                guard let hit = themeFrame.hitTest(midInTheme),
                      hit === actionView || hit.isDescendant(of: actionView) else {
                    logFailure("\(label): unified toolbar action hitTest failed at \(rectInWindow)")
                    return false
                }
            }
        }

        // On macOS <26 (Sequoia) titlebarSeparatorStyle == .none suppresses the toolbar hairline;
        // on macOS 26+, cassiniUnifiedToolbarChrome() suppresses ThinFilmPocket's permanent hairline when !forceLegacy.
        let expectToolbarSeparatorSuppressed = !isNativeMacOS26Available || (applyUnifiedToolbarChrome && !forceLegacy)

        // 1. Verify no AppKit horizontal separator view or visible pocket/toolbar Separator layer at rest.
        if expectToolbarSeparatorSuppressed
            && hasVisiblePocketOrToolbarSeparatorLayer(in: themeFrame, maxMinX: themeFrame.bounds.width) {
            logFailure("\(label): visible Pocket/Toolbar Separator layer at rest")
            return false
        } else if hasPinnedLeftHeader && expectToolbarSeparatorSuppressed
            && hasVisiblePocketOrToolbarSeparatorLayer(in: themeFrame, maxMinX: leftPaneWidth) {
            logFailure("\(label): visible Pocket Separator layer at rest in left pane")
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
                let inHeaderBelowToolbar = rect.maxY <= window.contentLayoutRect.maxY + 1 && rect.minY > windowHeight - 180
                let inToolbarZone = expectToolbarSeparatorSuppressed && rect.minY > windowHeight - 180
                let spansHorizontally = rect.width >= min(leftPaneWidth - 40, 180) && rect.height <= 2
                if (inHeaderBelowToolbar || inToolbarZone) && spansHorizontally {
                    logFailure("\(label): horizontal separator view \(className) at \(rect)")
                    return false
                }
            }
        }

        // 2. Verify rendered bitmap at rest: zero 1px separator spike at unified toolbar boundary and below pinned header.
        guard let restBitmap = renderBitmap(of: themeFrame) else {
            logFailure("\(label): renderBitmap at rest failed")
            return false
        }
        if expectToolbarSeparatorSuppressed {
            if hasOnePixelSeparatorSpike(in: restBitmap, x: rightSampleX, aroundY: toolbarBoundaryY, radius: 4) {
                logFailure("\(label): 1px toolbar hairline spike at rest x=\(rightSampleX) around y=\(toolbarBoundaryY)")
                return false
            }
            if !verifyNavigationSidebarSoftPocket
                && hasOnePixelSeparatorSpike(in: restBitmap, x: 5, aroundY: toolbarBoundaryY, radius: 4) {
                logFailure("\(label): 1px left-sidebar toolbar hairline spike at rest x=5 around y=\(toolbarBoundaryY)")
                return false
            }
            if isNativeMacOS26Available && !verifyNavigationSidebarSoftPocket {
                let maxStep = maxAdjacentLuminanceStep(
                    in: restBitmap,
                    x: rightSampleX,
                    minY: toolbarBoundaryY - 4,
                    maxY: toolbarBoundaryY + 6
                )
                if maxStep > 0.012 {
                    logFailure("\(label): expected seamless paneGround across unified toolbar at rest, maxStep=\(maxStep) around y=\(toolbarBoundaryY)")
                    return false
                }
            }
        }

        let leftScrollViews = allViews.compactMap { $0 as? NSScrollView }.filter {
            let r = $0.convert($0.bounds, to: nil)
            return r.minX < leftPaneWidth && r.height > 100
        }
        if checkHeaderHairlineSpike, let leftScroll = leftScrollViews.first {
            let scrollRect = leftScroll.convert(leftScroll.bounds, to: nil)
            let boundaryY = Int((windowHeight - scrollRect.maxY).rounded())
            let sampleX = Int(min(leftPaneWidth - 20, max(20, leftPaneWidth - 28)))
            if hasOnePixelSeparatorSpike(in: restBitmap, x: sampleX, aroundY: boundaryY, radius: 3) {
                logFailure("\(label): 1px hairline spike at x=\(sampleX) around y=\(boundaryY)")
                return false
            }
        }

        // 3. Verify search field width, hit-testing (not blocked by drop overlay or toolbar), and focus.
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
            guard rectInWindow.maxY <= window.contentLayoutRect.maxY + 1 else {
                logFailure("\(label): searchField maxY \(rectInWindow.maxY) overlaps unified toolbar minY \(window.contentLayoutRect.maxY)")
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

        // 4. Verify scroll behavior on macOS 26+: soft top fade activates under the unified toolbar when scrolled
        // (with no hard 1px toolbar hairline spike), returns cleanly to rest, and stays unmasked on legacy fallback.
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
                if hasVisiblePocketOrToolbarSeparatorLayer(in: themeFrame, maxMinX: themeFrame.bounds.width) {
                    logFailure("\(label): unexpected visible NSScrollPocket Separator layer in NavigationSplitView")
                    return false
                }
            }

            let scrollViews = allViews.compactMap { $0 as? NSScrollView }.filter { $0.bounds.height > 120 }
            for sv in scrollViews {
                sv.contentView.scroll(to: NSPoint(x: 0, y: 160))
                sv.reflectScrolledClipView(sv.contentView)
            }
            pumpWindowLayout(window)

            guard let rightScroll = scrollViews.first(where: {
                let r = $0.convert($0.bounds, to: nil)
                return r.minX <= CGFloat(rightSampleX) && r.maxX >= CGFloat(rightSampleX)
            }), let scrolledBitmap = renderBitmap(of: themeFrame) else {
                logFailure("\(label): missing rightScroll or scrolledBitmap")
                return false
            }
            let rightRect = rightScroll.convert(rightScroll.bounds, to: nil)
            let topEdgeY = Int((windowHeight - rightRect.maxY).rounded()) + Int(rightScroll.contentInsets.top.rounded())
            let aboveToolbarLuma = luminance(in: scrolledBitmap, x: rightSampleX, y: max(1, toolbarBoundaryY - 4))
            let nearTopLuma = luminance(in: scrolledBitmap, x: rightSampleX, y: max(1, topEdgeY + 2))
            let midFadeLuma = luminance(in: scrolledBitmap, x: rightSampleX, y: min(Int(windowHeight) - 2, topEdgeY + 10))
            let midPaneLuma = luminance(in: scrolledBitmap, x: rightSampleX, y: min(Int(windowHeight) - 2, topEdgeY + 45))

            if expectNativeScrollFadeOnMacOS26 {
                if hasVisiblePocketOrToolbarSeparatorLayer(in: themeFrame, maxMinX: themeFrame.bounds.width) {
                    logFailure("\(label): unexpected visible Pocket/Toolbar Separator layer after scrolling")
                    return false
                }
                if hasOnePixelSeparatorSpike(in: scrolledBitmap, x: rightSampleX, aroundY: toolbarBoundaryY, radius: 3) {
                    logFailure("\(label): unexpected 1px hard toolbar hairline spike after scrolling around y=\(toolbarBoundaryY)")
                    return false
                }
                if abs(nearTopLuma - midPaneLuma) < 0.02 {
                    logFailure("\(label): expected soft fade luma delta >= 0.02, got near=\(nearTopLuma) mid=\(midPaneLuma) topEdgeY=\(topEdgeY)")
                    return false
                }
                let lowLuma = min(nearTopLuma, midPaneLuma)
                let highLuma = max(nearTopLuma, midPaneLuma)
                if midFadeLuma <= lowLuma + 0.003 || midFadeLuma >= highLuma - 0.003 {
                    logFailure("\(label): expected graduated soft fade midpoint between \(nearTopLuma) and \(midPaneLuma), got midFade=\(midFadeLuma)")
                    return false
                }
                if abs(aboveToolbarLuma - nearTopLuma) >= abs(aboveToolbarLuma - midPaneLuma) {
                    logFailure("\(label): expected scrolled top edge (\(nearTopLuma)) to blend toward unified toolbar (\(aboveToolbarLuma)) vs midPane (\(midPaneLuma))")
                    return false
                }

                // Scroll back to rest and verify the unified toolbar boundary returns to zero hairline / seamless fill.
                for sv in scrollViews {
                    sv.contentView.scroll(to: NSPoint(x: 0, y: -sv.contentInsets.top))
                    sv.reflectScrolledClipView(sv.contentView)
                }
                pumpWindowLayout(window)
                guard let returnedBitmap = renderBitmap(of: themeFrame) else {
                    logFailure("\(label): renderBitmap after returning to rest failed")
                    return false
                }
                if hasOnePixelSeparatorSpike(in: returnedBitmap, x: rightSampleX, aroundY: toolbarBoundaryY, radius: 4) {
                    logFailure("\(label): 1px toolbar hairline spike after returning to rest around y=\(toolbarBoundaryY)")
                    return false
                }
                if !verifyNavigationSidebarSoftPocket {
                    let returnedStep = maxAdjacentLuminanceStep(
                        in: returnedBitmap,
                        x: rightSampleX,
                        minY: toolbarBoundaryY - 4,
                        maxY: toolbarBoundaryY + 6
                    )
                    if returnedStep > 0.012 {
                        logFailure("\(label): expected seamless paneGround after returning to rest, maxStep=\(returnedStep) around y=\(toolbarBoundaryY)")
                        return false
                    }
                }
            } else {
                if abs(nearTopLuma - midPaneLuma) > 0.01 {
                    logFailure("\(label): expected unmasked legacy luma delta <= 0.01, got near=\(nearTopLuma) mid=\(midPaneLuma)")
                    return false
                }
            }
        }
        #else
        _ = expectNativeScrollFadeOnMacOS26
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
