import AppKit
import CoreAudio
import SwiftUI

struct ContentView: View {
    @Bindable var model: RecorderViewModel

    var body: some View {
        ZStack {
            GlassWindowBackground()
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                header
                sourceCard
                microphoneCard
                if let error = model.lastError {
                    errorBanner(error)
                }
                footer
            }
            .padding(22)
        }
        .frame(width: 480)
        .onAppear { model.bootstrap() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MeetRec")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Meeting audio recorder")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let startedAt = model.recordingStartDate {
                RecordingBadge(startedAt: startedAt)
            }
        }
        .padding(.top, 14)
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Meeting audio", systemImage: "speaker.wave.2.fill")
                    .font(.headline)
                Spacer()
                Button {
                    model.refreshAudioApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.state != .idle)
                .help("Refresh the list of audio-capable apps")
            }

            Picker("Source", selection: $model.selectedTarget) {
                Text("None").tag(nil as CaptureTarget?)
                Text("System audio (all apps)").tag(CaptureTarget.systemAudio as CaptureTarget?)
                if !model.audioApps.isEmpty {
                    Divider()
                    ForEach(model.audioApps) { app in
                        Text(app.name).tag(CaptureTarget.app(app) as CaptureTarget?)
                    }
                }
            }
            .labelsHidden()
            .disabled(model.state != .idle)

            Text("Apps show up here once they have used audio. Pick System audio to capture everything except MeetRec itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(GlassCard())
    }

    private var microphoneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Microphone", systemImage: "mic.fill")
                .font(.headline)

            Picker("Microphone", selection: $model.selectedMicID) {
                Text("None").tag(nil as AudioDeviceID?)
                ForEach(model.mics) { mic in
                    Text(mic.name).tag(mic.id as AudioDeviceID?)
                }
            }
            .labelsHidden()
            .disabled(model.state != .idle)

            if model.micAccessDenied {
                PermissionBanner(
                    text: "Microphone access is denied for MeetRec.",
                    buttonTitle: "Open System Settings",
                    action: Permissions.openMicrophoneSettings
                )
            }
        }
        .modifier(GlassCard())
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if message.contains("System Settings") {
                    Button("Open System Settings") {
                        if message.contains("Microphone") {
                            Permissions.openMicrophoneSettings()
                        } else {
                            Permissions.openSystemAudioRecordingSettings()
                        }
                    }
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            Button {
                model.lastError = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.yellow.opacity(0.3), lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                NSWorkspace.shared.open(RecordingSession.recordingsDirectory)
            } label: {
                Label("Recordings", systemImage: "folder")
            }
            .buttonStyle(.borderless)
            .help("Open ~/MeetRecRecordings in Finder")

            Spacer()

            if model.state == .preparing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting…")
                        .foregroundStyle(.secondary)
                }
            }

            if model.isRecording || model.state == .stopping {
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                        Text(model.state == .stopping ? "Stopping…" : "Stop")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 9)
                }
                .buttonStyle(PillButtonStyle(
                    colors: [Color(white: 0.35), Color(white: 0.18)],
                    shadow: .black.opacity(0.3)
                ))
                .disabled(model.state == .stopping)
            } else {
                Button {
                    Task { await model.startRecording() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle")
                        Text("Record")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 9)
                }
                .buttonStyle(PillButtonStyle(
                    colors: [Color(red: 1.0, green: 0.32, blue: 0.27), Color(red: 0.82, green: 0.10, blue: 0.14)],
                    shadow: .red.opacity(0.35)
                ))
                .disabled(!model.canRecord)
                .opacity(model.canRecord ? 1 : 0.5)
            }
        }
    }
}

// MARK: - Recording badge

struct RecordingBadge: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 0.5)) { context in
            let interval = max(0, context.date.timeIntervalSince(startedAt))
            let pulseOn = Int(interval * 2) % 2 == 0
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                    .opacity(pulseOn ? 1 : 0.35)
                    .animation(.easeInOut(duration: 0.3), value: pulseOn)
                Text("REC")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(.red)
                Text(Self.timeString(Int(interval)))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.red.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(.red.opacity(0.35), lineWidth: 1))
        }
    }

    static func timeString(_ seconds: Int) -> String {
        String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}

// MARK: - Permission banner

struct PermissionBanner: View {
    let text: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(buttonTitle, action: action)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Liquid glass chrome

/// Frosted, translucent window backdrop (behind-window blur).
struct GlassWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        DispatchQueue.main.async {
            view.window?.isMovableByWindowBackground = true
        }
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { }
}

/// Translucent rounded card with a soft specular border, glassmorphism-style.
struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.32), .white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
    }
}

struct PillButtonStyle: ButtonStyle {
    var colors: [Color]
    var shadow: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                Capsule().fill(
                    LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
                )
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: shadow, radius: 8, y: 3)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
