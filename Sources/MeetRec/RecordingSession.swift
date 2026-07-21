import AppKit
import AVFoundation
import Foundation
import ScreenCaptureKit

/// Coordinates one recording: up to two capture pipelines, their writers, and
/// the watchers that detect a source dying mid-recording. Any source death
/// stops the whole session; partial files are always kept.
@MainActor
final class RecordingSession {
    static let recordingsDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("MeetRecRecordings", isDirectory: true)

    var onSourceDied: ((String) -> Void)?

    private let target: CaptureTarget?
    private let display: SCDisplay?
    private let mic: MicDevice?

    private var appCapture: AppAudioCapture?
    private var appWriter: AudioFileWriter?
    private var micCapture: MicCapture?
    private var micWriter: AudioFileWriter?
    private var appTerminationObserver: NSObjectProtocol?
    private var stopped = false

    init(target: CaptureTarget?, display: SCDisplay?, mic: MicDevice?) {
        self.target = target
        self.display = display
        self.mic = mic
    }

    func start() async throws {
        let directory = Self.recordingsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw MeetRecError("Could not create \(directory.path): \(error.localizedDescription)")
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let stamp = formatter.string(from: Date())

        do {
            if let target {
                try await startAppCapture(target: target, into: directory, stamp: stamp)
            }
            if let mic {
                try startMicCapture(device: mic, into: directory, stamp: stamp)
            }
        } catch {
            await rollback()
            throw error
        }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        removeAppTerminationObserver()
        if let appCapture {
            await appCapture.stop()
            appWriter?.finalize()
        }
        if let micCapture {
            micCapture.stop()
            micWriter?.finalize()
        }
    }

    private func startAppCapture(target: CaptureTarget, into directory: URL, stamp: String) async throws {
        let url = directory.appendingPathComponent("\(stamp)-app.m4a")
        let writer = try AudioFileWriter(url: url, channels: 2)
        appWriter = writer
        let capture = AppAudioCapture()
        appCapture = capture
        try await capture.start(target: target, display: display, writer: writer) { [weak self] reason in
            Task { @MainActor in self?.sourceDied(reason) }
        }

        // A display-based application filter keeps streaming silence after the
        // captured app quits (didStopWithError never fires), so watch process
        // termination explicitly. Harmless duplicate signal in window mode.
        if let pid = target.processID {
            appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier == pid
                else { return }
                Task { @MainActor in self?.sourceDied("The captured application quit.") }
            }
        }
    }

    private func startMicCapture(device: MicDevice, into directory: URL, stamp: String) throws {
        let capture = MicCapture(deviceID: device.id)
        micCapture = capture
        let hardwareFormat = try capture.bind()
        let channels = min(2, hardwareFormat.channelCount)
        let url = directory.appendingPathComponent("\(stamp)-mic.m4a")
        let writer = try AudioFileWriter(url: url, channels: channels)
        micWriter = writer
        try capture.start(writer: writer) { [weak self] reason in
            Task { @MainActor in self?.sourceDied(reason) }
        }
    }

    private func sourceDied(_ reason: String) {
        guard !stopped else { return }
        onSourceDied?(reason)
    }

    private func rollback() async {
        stopped = true
        removeAppTerminationObserver()
        if let appCapture {
            await appCapture.stop()
        }
        micCapture?.stop()
        appWriter?.discardIfEmpty()
        micWriter?.discardIfEmpty()
    }

    private func removeAppTerminationObserver() {
        if let appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appTerminationObserver)
            self.appTerminationObserver = nil
        }
    }
}
