import CassiniKit
import CassiniLibrary
import SwiftUI

/// Mirrors Finder's Get Info: what the file is, whether its audio and transcript belong together.
struct InspectorView: View {
    @Bindable var session: SessionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(UXText.text("mac.inspector.title"))
                    .font(.headline)
                    .frame(minHeight: 28)

                IntegrityBadge(session: session)

                if let m = session.manifest {
                    InfoSection(UXText.text("mac.inspector.recording")) {
                        row(UXText.text("mac.inspector.duration"), formatClock(session.player?.durationMs ?? m.meeting.durationMs))
                        if let d = session.recordingDateText { row(UXText.text("mac.inspector.recorded"), d) }
                    }

                    InfoSection(UXText.text("library.preview.transcriptHeading")) {
                        if session.availableTranscripts.count > 1 {
                            Picker(UXText.text("library.preview.transcriptHeading"), selection: $session.selectedTranscriptId) {
                                ForEach(session.availableTranscripts) { t in
                                    Text(t.id).tag(Optional(t.id))
                                }
                            }
                            .font(.caption)
                        }
                        if let entry = currentEntry, let lang = session.timeline.flatMap({ _ in entry.language }) {
                            row(UXText.text("details.writing.language"), Self.languageName(lang))
                        }
                        row(UXText.text("common.speakers"), m.speakers.count.formatted())
                    }

                    if let file = session.file, !file.errors.isEmpty || !file.warnings.isEmpty {
                        InfoSection(UXText.text("mac.inspector.details")) {
                            ForEach(Array((file.errors + file.warnings).enumerated()), id: \.offset) { _, f in
                                Text(f.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } else if let file = session.file, !file.errors.isEmpty {
                    InfoSection(UXText.text("mac.inspector.details")) {
                        ForEach(Array(file.errors.enumerated()), id: \.offset) { _, f in
                            Text(f.message).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text(UXText.text("mac.inspector.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(UXText.text("mac.inspector.showInFinder")) { session.showInFinder() }
                        .disabled(session.fileURL == nil)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var currentEntry: TranscriptEntry? {
        session.availableTranscripts.first { $0.id == session.selectedTranscriptId }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? .caption.monospaced() : .caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.caption)
    }

    /// A stored recognizer language shown by its catalog name when one exists, else verbatim (D47).
    static func languageName(_ code: String) -> String {
        let id = "details.language." + (code.lowercased().split(separator:"-").first.map(String.init) ?? "")
        return LibraryLocalization.shared.contains(id) ? UXText.text(id) : code
    }
}

struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

struct IntegrityBadge: View {
    let session: SessionModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var state: TrustState? { session.file?.state }

    private var icon: String {
        switch state {
        case .ok?: return "checkmark.seal"
        case .staleAudio?: return "exclamationmark.triangle"
        case .unverified?: return "questionmark.circle"
        case .plainAudio?: return "waveform"
        case .unknownCassiniFormat?: return "doc.badge.clock"
        case .invalidCassiniMetadata?, nil: return "xmark.octagon"
        }
    }

    private var color: Color {
        switch state {
        case .ok?: return .green
        case .staleAudio?: return .orange
        case .invalidCassiniMetadata?, nil: return .red
        default: return .secondary
        }
    }

    private var headline: String {
        switch state {
        case .ok?: return UXText.text("mac.inspector.audio.ok")
        case .staleAudio?: return UXText.text("mac.inspector.audio.staleAudio")
        case .unverified?: return UXText.text("mac.inspector.audio.unverified")
        case .plainAudio?: return UXText.text("mac.inspector.audio.plainAudio")
        case .unknownCassiniFormat?: return UXText.text("mac.inspector.audio.newerFormat")
        case .invalidCassiniMetadata?: return UXText.text("mac.inspector.audio.invalid")
        case nil: return UXText.text("mac.inspector.audio.unreadable")
        }
    }

    private var detail: String {
        switch state {
        // Only published copy is shown; reader diagnostics stay in the Details section.
        case .plainAudio?: return UXText.text("mac.inspector.audio.plainAudioDetail")
        default: return ""
        }
    }
}
