import CassiniKit
import SwiftUI

struct SidebarView: View {
    @Bindable var session: SessionModel

    var body: some View {
        List {
            if !session.speakers.isEmpty {
                Section("Speakers") {
                    ForEach(session.speakers) { speaker in
                        Toggle(isOn: binding(for: speaker.id)) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color(nsColor: session.color(for: speaker.id)))
                                    .frame(width: 8, height: 8)
                                Text(speaker.label)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if session.speakingNow.contains(speaker.id), !session.hiddenSpeakers.contains(speaker.id) {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityLabel("Speaking now")
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if !session.fileName.isEmpty {
                Label(session.fileName, systemImage: "doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !session.hiddenSpeakers.contains(id) },
            set: { on in
                if on { session.hiddenSpeakers.remove(id) } else { session.hiddenSpeakers.insert(id) }
            }
        )
    }
}
