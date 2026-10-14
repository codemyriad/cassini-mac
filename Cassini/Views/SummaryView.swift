import SwiftUI

/// The meeting summary, from the manifest's `summary.md` attachment. Timestamps in the text
/// (`1:38`, `12:04`, `1:02:30`) become links that jump to the transcript.
struct SummaryView: View {
    let markdown: String
    let session: SessionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    block
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "cassini", url.host == "seek", let ms = Int(url.lastPathComponent) else { return .systemAction }
            session.goToTranscript(ms: ms)
            return .handled
        })
    }

    private var blocks: [Text] {
        markdown.components(separatedBy: "\n\n").compactMap { para -> Text? in
            let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                let text = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return Text(attributed(text)).font(level == 1 ? .title2.bold() : .headline)
            }
            return Text(attributed(trimmed)).font(.body)
        }
    }

    private func attributed(_ s: String) -> AttributedString {
        var a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        let pattern = /\b(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\b/
        let plain = String(a.characters)
        for m in plain.matches(of: pattern) {
            let h = m.1.flatMap { Int($0) } ?? 0
            guard let min = Int(m.2), let sec = Int(m.3), sec < 60 else { continue }
            let ms = ((h * 60 + min) * 60 + sec) * 1000
            if let range = Range(m.range, in: a) {
                a[range].link = URL(string: "cassini://seek/\(ms)")
                a[range].foregroundColor = .accentColor
            }
        }
        return a
    }
}
