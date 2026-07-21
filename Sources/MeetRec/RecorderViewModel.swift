import AVFoundation
import Foundation

@MainActor
final class RecorderViewModel {
    /// Non-nil while recording; doubles as the session start timestamp that
    /// the elapsed display and file naming derive from.
    private(set) var recordingStartDate: Date?

    // Source selections, frozen by the menu while recording.
    /// true = All Apps, false = None.
    var systemAudioEnabled = true
    /// true = the system default input (follows the OS when devices come
    /// and go), false = None.
    var micEnabled = true

    // UI hooks — the app has no windows, so the status item refreshes and
    // alerts present through the controller.
    var onExternalChange: (() -> Void)?
    var onError: ((String) -> Void)?

    private var micCapture: MicCapture?
    private var systemCapture: ProcessTapCapture?
    private var session: (stamp: String, folder: URL)?
    /// Rejects re-entry while the permission request is awaited.
    private var isStarting = false

    var isRecording: Bool { recordingStartDate != nil }
    var canRecord: Bool { systemAudioEnabled || micEnabled }

    /// Starts all selected captures into a fresh session folder:
    /// ~/MeetRecRecordings/<stamp>/<stamp>-<source>.m4a
    func startRecording() async throws {
        guard !isRecording, !isStarting, canRecord else { return }
        isStarting = true
        defer { isStarting = false }

        if micEnabled {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw MeetRecError(
                    "Microphone access is denied. Allow MeetRec in System Settings › Privacy & Security › Microphone."
                )
            }
        }

        let startedAt = Date()
        let stamp = Self.stamp(for: startedAt)
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("MeetRecRecordings")
            .appendingPathComponent(stamp)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        if systemAudioEnabled {
            do {
                systemCapture = try ProcessTapCapture(url: folder.appendingPathComponent("\(stamp)-system.m4a"))
            } catch {
                removeIfEmpty(folder)
                throw error
            }
        }
        if micEnabled {
            do {
                micCapture = try makeMicCapture(url: folder.appendingPathComponent("\(stamp)-mic.m4a"))
            } catch {
                systemCapture?.stop()
                systemCapture = nil
                removeIfEmpty(folder)
                throw error
            }
        }

        session = (stamp, folder)
        recordingStartDate = startedAt
    }

    func stopRecording() {
        micCapture?.stop()
        micCapture = nil
        systemCapture?.stop()
        systemCapture = nil
        session = nil
        recordingStartDate = nil
    }

    // MARK: - Mic failover

    private func makeMicCapture(url: URL) throws -> MicCapture {
        let capture = try MicCapture(url: url)
        capture.onDied = { [weak self] in
            MainActor.assumeIsolated { self?.handleMicDeath() }
        }
        return capture
    }

    /// The captured device died: restart capture on whatever the system
    /// default input is now, continuing into a new segment file named by
    /// its offset from the session start. Success is silent.
    private func handleMicDeath() {
        guard isRecording, let session, let startedAt = recordingStartDate else { return }
        micCapture?.stop()
        micCapture = nil

        let centiseconds = Int((Date().timeIntervalSince(startedAt) * 100).rounded())
        let offset = String(
            format: "%02d%02d%02d%02d",
            centiseconds / 360_000,
            centiseconds / 6_000 % 60,
            centiseconds / 100 % 60,
            centiseconds % 100
        )
        let url = session.folder.appendingPathComponent("\(session.stamp)-mic-\(offset).m4a")
        do {
            micCapture = try makeMicCapture(url: url)
        } catch {
            if systemAudioEnabled {
                onError?("The microphone was lost and no input could take over. Recording continues without it.")
            } else {
                stopRecording()
                onExternalChange?()
                onError?("The microphone was lost and no input could take over. The recording was stopped.")
            }
        }
    }

    private func removeIfEmpty(_ folder: URL) {
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path), contents.isEmpty {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private static func stamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date)
    }
}

struct MeetRecError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
