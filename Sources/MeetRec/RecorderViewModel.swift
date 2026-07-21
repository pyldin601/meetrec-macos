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

    private var micCapture: MicCapture?
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

        if micEnabled {
            do {
                micCapture = try MicCapture(url: folder.appendingPathComponent("\(stamp)-mic.m4a"))
            } catch {
                removeIfEmpty(folder)
                throw error
            }
        }
        // System audio capture is the next step; its selection records
        // nothing yet.

        recordingStartDate = startedAt
    }

    func stopRecording() {
        micCapture?.stop()
        micCapture = nil
        recordingStartDate = nil
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
