// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CassiniRecording
import SwiftUI

struct RecordingView: View {
    @State private var recorder = RecordingController.shared
    @State private var review: RecordingManifest?
    @State private var reviewDirectory: URL?
    @State private var reviewScope: URL?
    @State private var players: [AVAudioPlayer] = []
    @State private var reviewError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Record a meeting").font(.largeTitle.bold())
                Text("Keep microphone and output audio as separate local tracks.")
                    .foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("Recording title", text: $recorder.title)
                        Picker("Output", selection: $recorder.output) {
                            ForEach(RecordingController.Output.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        if recorder.output == .application {
                            HStack {
                                Text("Select the audio processes to include.")
                                Spacer()
                                Button("Refresh") { recorder.refreshProcesses() }
                            }
                            if recorder.processes.isEmpty {
                                Text("Play audio in the meeting app, then refresh.").foregroundStyle(.secondary)
                            }
                            ForEach(recorder.processes) { process in
                                Toggle(process.name, isOn: Binding(
                                    get: { recorder.selectedProcesses.contains(process.id) },
                                    set: { if $0 { recorder.selectedProcesses.insert(process.id) } else { recorder.selectedProcesses.remove(process.id) } }
                                ))
                            }
                            Text("Browsers may use helper processes shared by several tabs. Use the browser extension to isolate a meeting tab.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Record microphone", isOn: $recorder.includeMicrophone)
                        if recorder.includeMicrophone {
                            Text("The microphone is recorded independently, including when you are muted in the meeting.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if recorder.output == .system {
                            Text("System output includes other apps and notifications.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(8)
                }.disabled(recorder.isRecording || recorder.isStarting)
                HStack(spacing: 16) {
                    if recorder.isRecording {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        if let started = recorder.startedAt {
                            TimelineView(.periodic(from: started, by: 1)) { context in
                                Text(Duration.seconds(max(0, context.date.timeIntervalSince(started))).formatted(.time(pattern: .hourMinuteSecond)))
                                    .monospacedDigit()
                            }
                        }
                        Button("Stop Recording") { recorder.stop() }.buttonStyle(.borderedProminent)
                    } else {
                        Button(recorder.isStarting ? "Starting…" : "Start Recording…") { Task { await recorder.start() } }
                            .buttonStyle(.borderedProminent).disabled(!recorder.canStart)
                    }
                    if recorder.directory != nil {
                        Button("Show Files") { recorder.reveal() }
                    }
                }
                if let problem = recorder.problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
                if recorder.isRecording {
                    ForEach(recorder.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                    if recorder.output != .none { level("Output audio", value: recorder.levels["output", default: 0]) }
                    if recorder.includeMicrophone { level("Microphone", value: recorder.levels["microphone", default: 0]) }
                    if recorder.waitingForAudio {
                        Text("Still waiting for one of the audio sources. Check permissions, input devices, and the selected processes.")
                            .foregroundStyle(.orange)
                    }
                }
                Text("Closing this window keeps recording. Use Stop Recording to finish; quitting Cassini also saves and stops.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Browser recording").font(.title2.bold())
                Text("Use the Cassini Chromium extension to record WebRTC tracks or a tab’s audio. Browser recordings are saved in Music/Cassini. Open a recording folder below to listen to its tracks.")
                Button("Open Recording Folder…") { openRecording() }.disabled(recorder.isRecording || recorder.isStarting)
                if let review {
                    Text(review.title).font(.headline)
                    Text("\(review.state.capitalized) · \(review.tracks.count) tracks").foregroundStyle(.secondary)
                    if let issue = review.problem { Text(issue).foregroundStyle(.orange) }
                    if review.state == "recording" { Text("This session may still be recording or may have been interrupted.").foregroundStyle(.orange) }
                    ForEach(review.tracks) { track in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(track.label)
                                Text("\(track.kind) · \(track.sampleRate) Hz · \(track.channels) channels").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Listen") { play([track]) }.disabled(recorder.isRecording || recorder.isStarting)
                        }
                    }
                    HStack {
                        Button("Listen to All") { play(review.tracks) }.disabled(recorder.isRecording || recorder.isStarting)
                        Button("Stop Playback") { stopPlayback() }
                    }
                }
                if let reviewError { Text(reviewError).foregroundStyle(.red) }
                Text("Recordings currently contain audio and source metadata. Transcription and portable Cassini Opus export are not included.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 620)
        .background(WindowAccessor { if let window = $0 { RecordingConfirmation.attach(to: window) } })
        .onAppear { recorder.refreshProcesses() }
        .onChange(of: recorder.isStarting) { _, starting in if starting { stopPlayback() } }
        .onDisappear { stopPlayback(); reviewScope?.stopAccessingSecurityScopedResource(); reviewScope = nil }
    }

    private func stopPlayback() { players.forEach { $0.stop() }; players = [] }

    private func level(_ label: String, value: Float) -> some View {
        HStack {
            Text(label).frame(width: 110, alignment: .leading)
            ProgressView(value: Double(value)).accessibilityLabel(label)
        }
    }

    private func openRecording() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        stopPlayback()
        reviewScope?.stopAccessingSecurityScopedResource()
        reviewScope = url.startAccessingSecurityScopedResource() ? url : nil
        review = nil
        reviewDirectory = nil
        do {
            let manifest = try RecordingLoader.load(directory: url)
            review = manifest
            reviewDirectory = url
            reviewError = nil
        } catch { reviewError = error.localizedDescription }
    }

    private func play(_ tracks: [RecordingTrack]) {
        stopPlayback()
        guard let reviewDirectory else { return }
        do {
            for track in tracks {
                guard track.file == URL(fileURLWithPath: track.file).lastPathComponent,
                      track.file.hasSuffix(".wav"), (track.startOffsetMs ?? 0).isFinite,
                      (0...86_400_000).contains(track.startOffsetMs ?? 0) else {
                    throw RecordingError.invalid("Invalid recording track.")
                }
                let url = reviewDirectory.appendingPathComponent(track.file).resolvingSymlinksInPath()
                guard url.deletingLastPathComponent() == reviewDirectory.resolvingSymlinksInPath() else {
                    throw RecordingError.invalid("The audio track is outside this recording folder.")
                }
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                players.append(player)
            }
            if let clock = players.first?.deviceCurrentTime {
                let base = tracks.count == 1 ? (tracks.first?.startOffsetMs ?? 0) : 0
                for (player, track) in zip(players, tracks) {
                    player.play(atTime: clock + 0.15 + ((track.startOffsetMs ?? 0) - base) / 1000)
                }
            }
            reviewError = nil
        } catch { stopPlayback(); reviewError = error.localizedDescription }
    }
}
