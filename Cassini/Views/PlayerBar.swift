import CassiniKit
import SwiftUI

/// Transport controls, pinned to the bottom of the content column.
struct PlayerBar: View {
    @Bindable var session: SessionModel
    @Bindable var player: PlayerController

    var body: some View {
        VStack(spacing: 6) {
            if let error = player.playbackError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            controls
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Button {
                    session.seek(toMs: player.currentMs - PlayerController.skipMs)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 20))
                        .frame(width: 36, height: 36)
                }
                .help("Back 15 seconds")
                .accessibilityLabel("Back 15 seconds")

                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor, in: Circle())
                        .contentShape(Circle())
                }
                .help(player.isPlaying ? "Pause" : "Play")
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button {
                    session.seek(toMs: player.currentMs + PlayerController.skipMs)
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 20))
                        .frame(width: 36, height: 36)
                }
                .help("Forward 15 seconds")
                .accessibilityLabel("Forward 15 seconds")
            }
            .buttonStyle(.borderless)

            Text(formatClock(player.currentMs))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { Double(player.currentMs) },
                    set: { session.seek(toMs: Int($0)) }
                ),
                in: 0...Double(max(player.durationMs, 1))
            )
            .controlSize(.small)
            .accessibilityLabel("Playback position")

            Text("-" + formatClock(max(0, player.durationMs - player.currentMs)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 42, alignment: .leading)

            Button {
                player.cycleSpeed()
            } label: {
                Text(speedLabel)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 36)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Playback speed")
            .accessibilityLabel("Playback speed \(speedLabel)")

            Toggle("Follow along", isOn: $session.follow)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(session.timeline == nil)
                .onChange(of: session.follow) { _, on in
                    if on { session.jumpToCurrent() }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .disabled(player.playbackError != nil)
    }

    private var speedLabel: String {
        let s = player.speed
        return (s == s.rounded() ? String(Int(s)) : String(s)) + "×"
    }
}
