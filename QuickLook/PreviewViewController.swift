import AppKit
import CassiniKit
import Quartz

/// Quick Look preview: the title, the speakers and the first lines of the transcript.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let textView = NSTextView()
    private let scrollView = NSScrollView()

    override func loadView() {
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 18)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        scrollView.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        view = scrollView
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try CassiniReader.read(contentsOf: url, verifyAudio: false) }
            DispatchQueue.main.async {
                switch result {
                case .success(let file):
                    self.textView.textStorage?.setAttributedString(PreviewText.build(file, fileName: url.lastPathComponent))
                    handler(nil)
                case .failure(let error):
                    handler(error)
                }
            }
        }
    }
}

enum PreviewText {
    static let maxTurns = 12
    static let maxWordsPerTurn = 40

    static func build(_ file: CassiniFile, fileName: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let title = file.manifest?.meeting.title ?? file.tags?["TITLE"] ?? fileName
        out.append(NSAttributedString(string: title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: NSColor.labelColor,
        ]))

        var meta: [String] = []
        if let m = file.manifest {
            meta.append(m.speakers.count == 1 ? "1 speaker" : "\(m.speakers.count) speakers")
            meta.append(formatClock(m.meeting.durationMs))
            meta.append(SessionDate.text(m))
        } else {
            meta.append(file.stateReason ?? "No transcript in this file")
        }
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = 14
        out.append(NSAttributedString(string: meta.filter { !$0.isEmpty }.joined(separator: " · ") + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p,
        ]))

        guard let m = file.manifest, let t = file.defaultTranscript?.load.transcript else { return out }
        if !m.speakers.isEmpty {
            out.append(NSAttributedString(string: m.speakers.map(\.label).joined(separator: ", ") + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p,
            ]))
        }
        let timeline = Timeline(t.items)
        let body = NSMutableParagraphStyle()
        body.paragraphSpacing = 10
        body.lineHeightMultiple = 1.2
        for turn in timeline.turns.prefix(maxTurns) {
            let label = m.speaker(turn.speaker)?.label ?? "Unknown speaker"
            out.append(NSAttributedString(string: "\(label)  ", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: body,
            ]))
            out.append(NSAttributedString(string: formatClock(turn.startMs) + "\n", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: body,
            ]))
            var words = turn.words.prefix(maxWordsPerTurn).map { timeline.words[$0].text }.joined(separator: " ")
            if turn.words.count > maxWordsPerTurn { words += " …" }
            out.append(NSAttributedString(string: words + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: body,
            ]))
        }
        if timeline.turns.count > maxTurns {
            out.append(NSAttributedString(string: "Open in Cassini for the whole transcript.", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        return out
    }
}

enum SessionDate {
    static func text(_ m: Manifest) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        if let local = m.meeting.recordedAtLocal {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            if let d = f.date(from: local) {
                var s = style
                s.timeZone = TimeZone(identifier: "UTC")!
                return d.formatted(s)
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: m.meeting.createdAtUtc) { return d.formatted(style) }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: m.meeting.createdAtUtc) { return d.formatted(style) }
        return ""
    }
}
