import AppKit
import AVFoundation
import Foundation

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
    private let mic: MicDevice?

    private var appCapture: ProcessTapCapture?
    private var appWriter: AudioFileWriter?
    private var micCapture: MicCapture?
    private var micWriter: AudioFileWriter?
    private var appTerminationObserver: NSObjectProtocol?
    private var stopped = false

    init(target: CaptureTarget?, mic: MicDevice?) {
        self.target = target
        self.mic = mic
    }

    func start() throws {
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
                try startAppCapture(target: target, into: directory, stamp: stamp)
            }
            if let mic {
                try startMicCapture(device: mic, into: directory, stamp: stamp)
            }
        } catch {
            rollback()
            throw error
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        removeAppTerminationObserver()
        if let appCapture {
            appCapture.stop()
            appWriter?.finalize()
        }
        if let micCapture {
            micCapture.stop()
            micWriter?.finalize()
        }
    }

    private func startAppCapture(target: CaptureTarget, into directory: URL, stamp: String) throws {
        let url = directory.appendingPathComponent("\(stamp)-\(target.fileSuffix).m4a")
        let writer = try AudioFileWriter(url: url, channels: 2)
        appWriter = writer
        let capture = ProcessTapCapture()
        appCapture = capture
        try capture.start(target: target, writer: writer)

        // The tap keeps producing silence after the captured app quits, so
        // watch process termination explicitly. Not needed for system audio.
        if let pid = target.pid {
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

    private func rollback() {
        stopped = true
        removeAppTerminationObserver()
        appCapture?.stop()
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
