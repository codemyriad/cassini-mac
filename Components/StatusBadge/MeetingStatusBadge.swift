// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Visual kinds from canvas Badge-Mac (L-26). The caller owns state precedence
/// and localized labels; this component never reads legacy badge tint strings.
enum StatusBadgeKind: String, CaseIterable {
    case recording, importing, saving, transcribing, attention, interrupted, received

    enum Glyph: Equatable { case dot, spinner, alert, incoming }
    var glyph: Glyph {
        switch self {
        case .recording: return .dot
        case .importing, .saving, .transcribing: return .spinner
        case .attention, .interrupted: return .alert
        case .received: return .incoming
        }
    }
    var ink: CassiniTokens.Entry {
        switch self {
        case .recording: return CassiniTokens.recordInkEntry
        case .attention, .interrupted: return CassiniTokens.warnInkEntry
        default: return CassiniTokens.ink2Entry
        }
    }
    /// L-45: on all four apps, the transcribing badge's spinner glyph uses accent.
    var glyphInk: CassiniTokens.Entry {
        self == .transcribing ? CassiniTokens.accentEntry : ink
    }
    var fill: CassiniTokens.Entry? {
        switch self {
        case .recording: return CassiniTokens.recordTintEntry
        case .attention, .interrupted: return CassiniTokens.warnTintEntry
        case .received: return nil
        default: return CassiniTokens.inkEntry
        }
    }
    /// L-46 / L-54: neutral pills composite ink at 10% over whatever is behind.
    var fillOpacity: Double {
        switch self {
        case .importing, .saving, .transcribing: return 0.1
        default: return 1
        }
    }
}

/// Shared status badge (L-26, L-45, L-46, L-54): 22px tall, 12px weight-600, 8px horizontal pad, 4px gap.
struct MeetingStatusBadge: View {
    let kind: StatusBadgeKind
    let label: String
    var isAnimating = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Metrics {
        static let height = 22.0
        static let font = 12.0
        static let horizontalPadding = 8.0
        static let gap = 4.0
        static let dotSize = 6.0
        static let spinnerSize = 10.0
        static let symbolSize = 11.0
        static let outlineWidth = 1.0
    }

    private func color(_ entry: CassiniTokens.Entry) -> Color {
        Color(nsColor: entry.resolvedNSColor(dark: scheme == .dark))
    }

    var body: some View {
        HStack(spacing: Metrics.gap) {
            glyph.accessibilityHidden(true)
            Text(label).font(.system(size: Metrics.font, weight: .semibold))
                .monospacedDigit().fixedSize(horizontal: true, vertical: true)
                .foregroundStyle(color(kind.ink))
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .frame(height: Metrics.height)
        .fixedSize(horizontal: true, vertical: true)
        .background {
            if let fill = kind.fill { Capsule().fill(color(fill).opacity(kind.fillOpacity)) }
        }
        .overlay {
            if kind == .received { Capsule().strokeBorder(color(CassiniTokens.lineEntry), lineWidth: Metrics.outlineWidth) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }

    @ViewBuilder private var glyph: some View {
        switch kind.glyph {
        case .dot:
            Circle().fill(color(kind.glyphInk)).frame(width: Metrics.dotSize, height: Metrics.dotSize)
        case .spinner:
            if isAnimating && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                    BadgeGlyph(glyph: .spinner, ink: color(kind.glyphInk))
                        .rotationEffect(.degrees(phase * 360))
                }.frame(width: Metrics.spinnerSize, height: Metrics.spinnerSize)
            } else {
                BadgeGlyph(glyph: .spinner, ink: color(kind.glyphInk)).frame(width: Metrics.spinnerSize, height: Metrics.spinnerSize)
            }
        case .alert, .incoming:
            BadgeGlyph(glyph: kind.glyph, ink: color(kind.glyphInk)).frame(width: Metrics.symbolSize, height: Metrics.symbolSize)
        }
    }
}

/// Canvas paths preserve the glyph's stroke widths and round caps at Mac size.
private struct BadgeGlyph: View {
    let glyph: StatusBadgeKind.Glyph
    let ink: Color
    var body: some View {
        Canvas { context, size in
            let box = glyph == .incoming ? 24.0 : 16.0
            context.scaleBy(x: size.width / box, y: size.height / box)
            switch glyph {
            case .spinner:
                context.stroke(Path(ellipseIn: CGRect(x: 2, y: 2, width: 12, height: 12)),
                               with: .color(ink.opacity(0.3)), lineWidth: 2.4)
                var arc = Path()
                arc.addArc(center: CGPoint(x: 8, y: 8), radius: 6,
                           startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
                context.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            case .alert:
                context.stroke(Path(ellipseIn: CGRect(x: 1.5, y: 1.5, width: 13, height: 13)),
                               with: .color(ink), lineWidth: 1.8)
                var mark = Path()
                mark.move(to: CGPoint(x: 8, y: 4.8)); mark.addLine(to: CGPoint(x: 8, y: 8.6))
                mark.move(to: CGPoint(x: 8, y: 11)); mark.addLine(to: CGPoint(x: 8, y: 11.01))
                context.stroke(mark, with: .color(ink), style: StrokeStyle(lineWidth: 1.9, lineCap: .round))
            case .incoming:
                var arrow = Path()
                arrow.addLines([CGPoint(x: 12, y: 4), CGPoint(x: 12, y: 14)])
                arrow.addLines([CGPoint(x: 8, y: 10), CGPoint(x: 12, y: 14), CGPoint(x: 16, y: 10)])
                arrow.addLines([CGPoint(x: 4, y: 16), CGPoint(x: 4, y: 19.5), CGPoint(x: 20, y: 19.5), CGPoint(x: 20, y: 16)])
                context.stroke(arrow, with: .color(ink), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            case .dot: break // The badge uses an exact 6 pt Circle for the dot.
            }
        }
    }
}
