import AppKit
import AVFoundation
import Foundation

/// Coordinates one recording: up to two capture pipelines, their writers, and
/// the watchers that detect a source dying mid-recording. The system-audio
/// capture lives for the whole session; the microphone side is segmented —
/// each attach starts a fresh MicCapture + AudioFileWriter pair writing a new
/// segment file, so a dead or switched mic never ends the session by itself.
/// Partial files are always kept (empty mid-session segments are deleted).
@MainActor
final class RecordingSession {
    static let recordingsDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("MeetRecRecordings", isDirectory: true)

    /// Fires when the captured application quits (per-app targets only).
    /// Stops the whole session.
    var onSourceDied: ((String) -> Void)?

    /// Fires when the active mic segment dies (device unplugged, or its
    /// engine stopped after a configuration change). The dead segment is
    /// already finalized and the session keeps running; the owner decides
    /// whether to attach a replacement.
    var onMicDied: (@MainActor (MicDevice, String) -> Void)?

    private let target: CaptureTarget?
    private let mic: MicDevice?

    private var appCapture: ProcessTapCapture?
    private var appWriter: AudioFileWriter?
    private var micCapture: MicCapture?
    private var micWriter: AudioFileWriter?
    private var appTerminationObserver: NSObjectProtocol?
    private var stopped = false

    private var directory: URL?
    private var stamp = ""
    private var sessionStart = Date()
    /// Counts started mic segments; the plain `-mic.m4a` name is reserved for
    /// segment 0, the one started with the session (SPEC.md §3.1).
    private var micSegmentIndex = 0
    /// Bumped on every mic segment teardown. Death callbacks carry the
    /// generation they were installed for, so signals from an already
    /// torn-down segment (a second watcher firing for the same unplug, or a
    /// callback queued behind a manual switch) are ignored.
    private var micGeneration = 0

    private(set) var activeMicDevice: MicDevice?

    var isMicActive: Bool { micCapture != nil }
    var isSystemAudioActive: Bool { appCapture != nil }

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
        self.directory = directory

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        sessionStart = Date()
        stamp = formatter.string(from: sessionStart)

        do {
            if let target {
                try startAppCapture(target: target, into: directory, stamp: stamp)
            }
            if let mic {
                try startMicSegment(device: mic)
            } else {
                // Segment 0's plain name is only for a mic that records from
                // the session start; a mid-session first attach gets a suffix.
                micSegmentIndex = 1
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
            // Same as finalize() for any segment with content; deletes a
            // zero-frame final segment per SPEC.md §3.1.
            micWriter?.discardIfEmpty()
        }
    }

    // MARK: - Mic segments

    /// Ends mic capture and finalizes the current segment (segments that
    /// captured nothing are deleted). The session keeps running.
    func detachMic() {
        guard !stopped else { return }
        finalizeCurrentMicSegment()
    }

    /// Starts a new mic segment on `device`, finalizing any active segment
    /// first. On failure the new segment's file is discarded, the session is
    /// left with no active mic (but keeps running), and the error rethrows.
    func attachMic(_ device: MicDevice) throws {
        guard !stopped else { return }
        finalizeCurrentMicSegment()
        try startMicSegment(device: device)
    }

    private func startMicSegment(device: MicDevice) throws {
        let capture = MicCapture(deviceID: device.id)
        let hardwareFormat = try capture.bind()
        let channels = min(2, hardwareFormat.channelCount)
        let writer = try AudioFileWriter(url: nextMicSegmentURL(), channels: channels)
        let generation = micGeneration
        do {
            try capture.start(writer: writer) { [weak self] reason in
                Task { @MainActor in self?.micSegmentDied(generation: generation, reason: reason) }
            }
        } catch {
            capture.stop()
            writer.discardIfEmpty()
            throw error
        }
        micCapture = capture
        micWriter = writer
        activeMicDevice = device
        micSegmentIndex += 1
    }

    private func nextMicSegmentURL() -> URL {
        let directory = self.directory ?? Self.recordingsDirectory
        guard micSegmentIndex > 0 else {
            return directory.appendingPathComponent("\(stamp)-mic.m4a")
        }
        var offset = max(0, Int(Date().timeIntervalSince(sessionStart)))
        while true {
            let name = String(
                format: "%@-mic-%02d%02d%02d.m4a",
                stamp, offset / 3600, (offset % 3600) / 60, offset % 60
            )
            let url = directory.appendingPathComponent(name)
            // AVAudioFile(forWriting:) truncates; never reuse a live name.
            if !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            offset += 1
        }
    }

    private func micSegmentDied(generation: Int, reason: String) {
        guard !stopped, generation == micGeneration, let device = activeMicDevice else { return }
        finalizeCurrentMicSegment()
        onMicDied?(device, reason)
    }

    private func finalizeCurrentMicSegment() {
        guard micCapture != nil || micWriter != nil else { return }
        micCapture?.stop()
        micWriter?.discardIfEmpty()
        micCapture = nil
        micWriter = nil
        activeMicDevice = nil
        micGeneration += 1
    }

    // MARK: - System audio

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
                Task { @MainActor in self?.appSourceDied("The captured application quit.") }
            }
        }
    }

    private func appSourceDied(_ reason: String) {
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
