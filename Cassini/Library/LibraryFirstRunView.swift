// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

struct LibraryFirstRunView: View {
    let root: URL
    let screenshot: Bool
    let dropState: LibraryDropState
    let onRecord: () -> Void
    @State private var captures = CaptureCollection.shared

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < FirstRunHeroMetrics.compactHeight
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? FirstRunHeroMetrics.compactGap : FirstRunHeroMetrics.gap) {
                    HStack(spacing: 32) {
                        CassiniBrandMark(height: FirstRunHeroMetrics.mark)
                        FirstRunWave().frame(maxWidth: 501).frame(height: FirstRunHeroMetrics.mark)
                    }.padding(.bottom, 4)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(UXText.text("firstRun.hero.title"))
                            .foregroundStyle(CassiniTheme.ink).accessibilityIdentifier("first-run-hero-title")
                        Text(UXText.text("firstRun.hero.subtitle.computer"))
                            .foregroundStyle(CassiniTheme.ink3).accessibilityIdentifier("first-run-hero-subtitle")
                    }.font(.system(size: FirstRunHeroMetrics.headline, weight: .bold)).tracking(-1.92)
                        .lineLimit(1).minimumScaleFactor(0.45)
                        .frame(maxWidth: .infinity, alignment: .leading).accessibilityAddTraits(.isHeader)
                    if let line = RecordingOverview.libraryDiskLine {
                        Text(line).foregroundStyle(CassiniTheme.warningNotice)
                    }
                    if captures.hasFailure {
                        CaptureFailureBanner()
                    }
                    HStack(spacing: 14) {
                        FirstRunRecordButton(action: onRecord).fixedSize()
                        FirstRunShortcut()
                    }
                    FirstRunPrivacy(root: root, screenshot: screenshot)
                }.padding(.horizontal, FirstRunHeroMetrics.horizontalPadding)
                    .padding(.vertical, compact ? FirstRunHeroMetrics.compactPadding : FirstRunHeroMetrics.padding)
                    .frame(maxWidth: FirstRunHeroMetrics.maxWidth + 2 * FirstRunHeroMetrics.horizontalPadding, alignment: .leading)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }.accessibilityElement(children: .contain).accessibilityLabel(UXText.text("library.title"))
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("first-run-library")
        }.background(CassiniTheme.surface)
            .overlay { LibraryDropListOverlay(state: dropState) }
    }
}

private struct FirstRunRecordButton: View {
    let action: () -> Void

    var body: some View {
        let saving = RecordingOverview.saving
        let enabled = RecordingOverview.canStart
        let title = UXText.text(saving ? "states.badge.saving" : "common.record")
        Button(action: action) {
            HStack(spacing: 9) {
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Circle().fill(enabled ? CassiniTheme.onRecord : CassiniTheme.ink3).frame(width: 10, height: 10)
                }
                Text(title).fontWeight(.semibold)
            }.font(.system(size: 15)).padding(.leading, 20).padding(.trailing, 24).frame(height: 46)
                .foregroundStyle(saving ? CassiniTheme.ink2 : enabled ? CassiniTheme.onRecord : CassiniTheme.ink3)
                .background(saving || !enabled ? CassiniTheme.chipFill : CassiniTheme.record, in: Capsule())
        }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel(title).accessibilityIdentifier("first-run-record")
    }
}

// D105: desktop headline size is decided; narrow/short windows remain usable.
private enum FirstRunHeroMetrics {
    static let headline: CGFloat = 64
    static let maxWidth: CGFloat = 860
    static let horizontalPadding: CGFloat = 48
    static let gap: CGFloat = 24
    static let compactGap: CGFloat = 16
    static let mark: CGFloat = 40
    static let padding: CGFloat = 32
    static let compactPadding: CGFloat = 24
    static let compactHeight: CGFloat = 600
}

/// D105 keeps the placeholder in its localized position, rendered as one key chip.
private struct FirstRunShortcut: View {
    private var parts: [String] { UXText.text("firstRun.shortcutLine").components(separatedBy: "{shortcut}") }
    var body: some View {
        HStack(spacing: 0) {
            Text(parts[0])
            Text(UXText.text("common.shortcut.record"))
                .font(.system(size: 13.5, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(CassiniTheme.chipFill, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(CassiniTheme.tagStroke))
                .fixedSize()
            Text(parts.dropFirst().joined(separator: "{shortcut}"))
                .fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 15)).foregroundStyle(CassiniTheme.ink2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(UXText.text("firstRun.shortcutLine", ["shortcut": UXText.text("common.shortcut.record")]))
            .accessibilityIdentifier("first-run-shortcut")
    }
}

private struct FirstRunPrivacy: View {
    // The observed Library context republishes this after Move completes, so
    // the displayed folder and the link target change together.
    let root: URL
    let screenshot: Bool
    private var move: LibraryMoveCoordinator { .shared }
    private static let folderLink = URL(string: "cassini-first-run://library")!
    private var line: AttributedString {
        // Build attributed text directly: folder names are literal, including
        // Markdown, braces, and punctuation. Only the catalog placeholder links.
        let parts = UXText.text("firstRun.privacy.computer").components(separatedBy: "{folder}")
        let folder = LibraryLocationModel.display(screenshot ? LibraryLocation.standardRoot : root)
            .replacingOccurrences(of: " › ", with: "/")
        var result = AttributedString(parts[0])
        var link = AttributedString(folder)
        link.link = Self.folderLink
        link.foregroundColor = CassiniTokens.accent
        link.font = .system(size: 14, weight: .semibold)
        link.underlineStyle = .single
        result.append(link)
        result.append(AttributedString(parts.dropFirst().joined(separator: "{folder}")))
        return result
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "shield").font(.system(size: 15)).foregroundStyle(CassiniTokens.accent).accessibilityHidden(true)
            Text(line).fixedSize(horizontal: false, vertical: true)
                .help(UXText.text("firstRun.openFolder.tooltip"))
                .environment(\.openURL, OpenURLAction { url in
                    guard url == Self.folderLink else { return .discarded }
                    openFolder()
                    return .handled
                })
                .accessibilityIdentifier("first-run-privacy")
            Button { move.choose(parent: NSApp.keyWindow) } label: {
                Image(systemName: "pencil").font(.system(size: 12)).frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(CassiniTheme.ink3)
                .help(UXText.text("firstRun.changeFolder.tooltip"))
                .accessibilityLabel(UXText.text("firstRun.changeFolder"))
                .accessibilityIdentifier("first-run-change-folder").disabled(!move.canChoose)
        }.font(.system(size: 14)).foregroundStyle(CassiniTheme.ink2)
    }
    private func openFolder() {
        let root = root
        Task {
            do {
                // A new default Library need not exist yet. Prepare it off the
                // main actor; a disconnected custom Library must not be recreated.
                try await Task.detached(priority: .utility) {
                    if root == LibraryLocation.standardRoot {
                        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    } else {
                        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw POSIXError(.ENOENT) }
                    }
                }.value
                NSWorkspace.shared.open(root)
            } catch { NSApp.presentError(error) }
        }
    }
}

/// Decorative and static: verbatim heights/fades from P2FirstRun-Desktop,
/// canvas 1794987301-5bc7. Four phrases, three pauses, then a fading tail.
private struct FirstRunWave: View {
    private static let bars: [(CGFloat, Double)] = [
        (7, 1.00), (22, 1.00), (12, 1.00), (23, 1.00), (22, 1.00), (25, 1.00), (30, 1.00), (19, 1.00),
        (30, 1.00), (24, 1.00), (14, 1.00), (15, 1.00), (22, 1.00), (8, 1.00), (10, 1.00), (15, 1.00),
        (25, 1.00), (19, 1.00), (23, 1.00), (18, 1.00), (19, 0.93), (8, 0.83), (6, 0.78), (6, 0.78),
        (8, 0.83), (13, 0.93), (14, 1.00), (18, 1.00), (17, 1.00), (14, 1.00), (19, 1.00), (15, 1.00),
        (11, 1.00), (13, 1.00), (11, 1.00), (16, 1.00), (22, 1.00), (22, 1.00), (16, 1.00), (12, 1.00),
        (13, 1.00), (8, 1.00), (15, 1.00), (20, 1.00), (15, 1.00), (25, 1.00), (18, 1.00), (18, 0.93),
        (6, 0.78), (12, 0.93), (19, 1.00), (15, 1.00), (15, 1.00), (17, 1.00), (16, 1.00), (9, 1.00),
        (17, 1.00), (25, 1.00), (27, 1.00), (32, 1.00), (19, 1.00), (18, 1.00), (35, 1.00), (16, 1.00),
        (16, 1.00), (15, 1.00), (22, 1.00), (10, 0.85), (6, 0.78), (6, 0.76), (8, 0.81), (17, 0.90),
        (22, 0.87), (23, 0.83), (19, 0.80), (15, 0.77), (8, 0.73), (11, 0.70), (6, 0.67), (6, 0.63),
        (6, 0.60), (6, 0.57), (6, 0.53), (6, 0.50),
    ]
    var body: some View {
        Canvas { context, size in
            // Preserve all phrases on narrow windows by reducing the gap only.
            let pitch = min(6, max(3, (size.width - 3) / CGFloat(Self.bars.count - 1)))
            for (index, level) in Self.bars.enumerated() {
                let bar = CGRect(x: CGFloat(index) * pitch, y: (size.height - level.0) / 2, width: 3, height: level.0)
                context.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(CassiniTheme.ink3.opacity(level.1)))
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}
