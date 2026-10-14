import CassiniKit
import SwiftUI

/// Mirrors Finder's Get Info: what the file is, whether its audio and transcript belong together.
struct InspectorView: View {
    @Bindable var session: SessionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("File Info")
                    .font(.headline)
                    .frame(minHeight: 28)

                IntegrityBadge(session: session)

                if let m = session.manifest {
                    InfoSection("Recording") {
                        row("Duration", formatClock(session.player?.durationMs ?? m.meeting.durationMs))
                        if let d = session.recordingDateText { row("Recorded", d) }
                        row("Format", "Ogg Opus")
                        row("Sample rate", "\(m.audio.sampleRate / 1000) kHz")
                        row("Channels", m.audio.channels == 1 ? "Mono" : "Stereo")
                    }

                    InfoSection("Transcript") {
                        if session.availableTranscripts.count > 1 {
                            Picker("Transcript", selection: $session.selectedTranscriptId) {
                                ForEach(session.availableTranscripts) { t in
                                    Text(t.id).tag(Optional(t.id))
                                }
                            }
                            .font(.caption)
                        }
                        if let entry = currentEntry {
                            row("Schema", entry.format, mono: true)
                            if let lang = session.timeline.flatMap({ _ in entry.language }) { row("Language", lang) }
                        }
                        row("Speakers", "\(m.speakers.count)")
                        if let tl = session.timeline {
                            row("Words", tl.words.count.formatted())
                            row("Timing", "Per word, ms")
                        }
                    }

                    if let prov = m.provenance, let lines = Optional(provenanceLines(prov)), !lines.isEmpty {
                        InfoSection("Provenance") {
                            ForEach(lines, id: \.0) { k, v in row(k, v) }
                        }
                    }

                    if let file = session.file, !file.errors.isEmpty || !file.warnings.isEmpty {
                        InfoSection("Details") {
                            ForEach(Array((file.errors + file.warnings).enumerated()), id: \.offset) { _, f in
                                Text(f.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } else if let file = session.file, !file.errors.isEmpty {
                    InfoSection("Details") {
                        ForEach(Array(file.errors.enumerated()), id: \.offset) { _, f in
                            Text(f.message).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text("Transcript and speakers live inside this .opus file, so any audio player can still play it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Show in Finder") { session.showInFinder() }
                        .disabled(session.fileURL == nil)
                    Button("Export…") { TranscriptExportPanel.run(for: session) }
                        .disabled(session.timeline == nil)
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

    /// Flattens provenance to "path: value" lines, strings and numbers only, as the spec keeps it.
    private func provenanceLines(_ json: JSON) -> [(String, String)] {
        var out: [(String, String)] = []
        func walk(_ j: JSON, _ path: String) {
            switch j {
            case .string(let s): out.append((path, s))
            case .number(let n): out.append((path, n))
            case .bool(let b): out.append((path, b ? "yes" : "no"))
            case .object(let members): for (k, v) in members { walk(v, path.isEmpty ? k : "\(path).\(k)") }
            case .array(let items):
                let strings = items.compactMap(\.string)
                if strings.count == items.count { out.append((path, strings.joined(separator: ", "))) }
                else { for (i, v) in items.enumerated() { walk(v, "\(path)[\(i)]") } }
            case .null: break
            }
        }
        walk(json, "")
        return Array(out.prefix(40))
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
        case .ok?: return "Audio matches transcript"
        case .staleAudio?: return "Audio doesn’t match transcript"
        case .unverified?: return "Audio not verified"
        case .plainAudio?: return "No transcript in this file"
        case .unknownCassiniFormat?: return "Newer Cassini format"
        case .invalidCassiniMetadata?: return "Transcript unreadable"
        case nil: return "Can’t read this file"
        }
    }

    private var detail: String {
        switch state {
        case .ok?: return "SHA-256 of the Opus audio checked against the file’s manifest."
        case .plainAudio?: return "An ordinary Opus file without Cassini metadata."
        case nil: return session.readError ?? ""
        default: return session.file?.stateReason ?? ""
        }
    }
}
