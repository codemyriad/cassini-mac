// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

/// D52.3a: one Recording details sheet, opened from a meeting's More menu or the
/// Recording page link. Live meetings refresh with each Library rescan.
@MainActor @Observable final class RecordingDetailsCoordinator {
    static let shared = RecordingDetailsCoordinator()
    var showing = false
    private(set) var key: String?
    func show(_ meeting: LibraryMeeting) { key = meeting.libraryKey; showing = true }
    func close() { showing = false }
}

extension RecordingDetailsReport.Lifecycle {
    init(_ lifecycle: MeetingLifecycle) {
        switch lifecycle { case .recording: self = .recording; case .saving: self = .saving; case .saved: self = .saved }
    }
}

struct RecordingDetailsSheet: View {
    @State private var store = LibraryStore.shared
    @State private var coordinator = RecordingDetailsCoordinator.shared
    @State private var report: RecordingDetailsReport?
    private func text(_ line: RecordingDetailsReport.Line) -> String { line.render(language:UXText.language,locale:UXText.locale) }
    private var meeting: LibraryMeeting? { store.meetings.first { $0.libraryKey == coordinator.key } }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            VStack(alignment:.leading,spacing:4) {
                Text(UXText.text("details.title")).font(.system(size:20,weight:.bold)).accessibilityAddTraits(.isHeader)
                if let subtitle = report?.subtitle { Text(text(subtitle)).foregroundStyle(LibraryTheme.dim) }
                if report?.updates == true { Text(UXText.text("details.updates")).font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim) }
            }
            VStack(alignment:.leading,spacing:8) {
                Text(UXText.text("details.sources.title")).font(.system(size:13,weight:.semibold)).accessibilityAddTraits(.isHeader)
                if let report, !report.sources.isEmpty {
                    ForEach(Array(report.sources.enumerated()),id:\.offset) { index,row in
                        VStack(alignment:.leading,spacing:2) {
                            Text(text(row.line)).foregroundStyle(row.problem ? Color.orange : Color.primary)
                                .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("recording-details-source-\(index)")
                            ForEach(Array(row.gapLines.enumerated()),id:\.offset) { gap,line in
                                Text(text(line)).font(.system(size:11.5)).foregroundStyle(.orange)
                                    .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("recording-details-gap-\(index)-\(gap)")
                            }
                        }
                    }
                } else {
                    Text(UXText.text("details.sources.empty")).foregroundStyle(LibraryTheme.dim).accessibilityIdentifier("recording-details-sources-empty")
                }
                ForEach(Array((report?.notes ?? []).enumerated()),id:\.offset) { _,note in
                    Text(text(note)).font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim).fixedSize(horizontal:false,vertical:true)
                }
            }
            VStack(alignment:.leading,spacing:6) {
                Text(UXText.text("details.end.title")).font(.system(size:13,weight:.semibold)).accessibilityAddTraits(.isHeader)
                if let report {
                    Text(text(report.ended)).foregroundStyle(report.endKnown ? Color.primary : LibraryTheme.dim).accessibilityIdentifier("recording-details-end")
                }
            }
            HStack {
                Spacer()
                Button(UXText.text("common.done")) { coordinator.close() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("recording-details-close")
            }
        }.font(.system(size:13)).padding(26).frame(width:480,alignment:.leading)
            .onExitCommand { coordinator.close() }
            .accessibilityElement(children:.contain).accessibilityIdentifier("recording-details-sheet")
            .task(id:"\(coordinator.key ?? "")#\(store.revision)") { await reload() }
    }
    /// Files are read off the main actor; a live meeting refreshes with each rescan.
    private func reload() async {
        guard let meeting else { report = nil; return }
        let folder = meeting.folder, lifecycle = RecordingDetailsReport.Lifecycle(meeting.state.lifecycle)
        let title = meeting.title ?? UXText.text("library.untitled"), done = meeting.state.transcript == .done
        let loaded = await Task.detached {
            RecordingDetailsReport(.load(folder:folder,lifecycle:lifecycle,title:title,transcriptDone:done))
        }.value
        guard !Task.isCancelled else { return }
        report = loaded
    }
}
