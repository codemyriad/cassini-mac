import SwiftUI

/// The meeting summary, from the manifest's `summary.md` attachment: headings, paragraphs, lists
/// and task items. Timestamps in the text (`1:38`, `12:04`, `1:02:30`) become links that jump to
/// the transcript.
struct SummaryView: View {
    let markdown: String
    let session: SessionModel
    /// Task items ticked in this window; the file is read-only, so this is session state.
    @State private var ticked: Set<Int> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    switch block {
                    case .heading(let text, let level):
                        Text(text)
                            .font(headingFont(level))
                            .padding(.top, index == 0 ? 0 : 6)
                    case .paragraph(let text):
                        Text(text).font(.body).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    case .list(let items):
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(items.enumerated()), id: \.offset) { n, item in
                                listRow(item, key: index * 1000 + n)
                            }
                        }
                    }
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

    @ViewBuilder
    private func listRow(_ item: ListItem, key: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let checked = item.checked {
                Toggle(isOn: Binding(
                    get: { ticked.contains(key) != checked },
                    set: { on in if on != checked { ticked.insert(key) } else { ticked.remove(key) } }
                )) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            } else if let n = item.ordinal {
                Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text("•").foregroundStyle(.secondary)
            }
            Text(item.text).font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.weight(.semibold)
        default: return .headline
        }
    }

    // MARK: Blocks

    private enum Block {
        case heading(AttributedString, Int)
        case paragraph(AttributedString)
        case list([ListItem])
    }

    private struct ListItem {
        var text: AttributedString
        var checked: Bool?
        var ordinal: Int?
    }

    private var blocks: [Block] {
        markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .compactMap { para -> Block? in
                let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                if trimmed.hasPrefix("#") {
                    let level = trimmed.prefix { $0 == "#" }.count
                    return .heading(attributed(trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)), level)
                }
                let lines = trimmed.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                let items = lines.compactMap(listItem)
                if !items.isEmpty, items.count == lines.count { return .list(items) }
                return .paragraph(attributed(trimmed))
            }
    }

    private func listItem(_ line: String) -> ListItem? {
        if let m = line.firstMatch(of: /^[-*+]\s+\[( |x|X)\]\s+(.*)$/) {
            return ListItem(text: attributed(String(m.2)), checked: m.1 != " ", ordinal: nil)
        }
        if let m = line.firstMatch(of: /^[-*+]\s+(.*)$/) {
            return ListItem(text: attributed(String(m.1)), checked: nil, ordinal: nil)
        }
        if let m = line.firstMatch(of: /^(\d{1,3})[.)]\s+(.*)$/) {
            return ListItem(text: attributed(String(m.2)), checked: nil, ordinal: Int(m.1))
        }
        return nil
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
