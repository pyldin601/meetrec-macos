import Foundation

@MainActor
final class RecorderViewModel {
    /// Non-nil while recording; doubles as the session start timestamp that
    /// the elapsed display (and later, file naming) derives from.
    private(set) var recordingStartDate: Date?

    // Source selections, frozen by the menu while recording.
    /// true = All Apps, false = None.
    var systemAudioEnabled = true
    /// true = the system default input (follows the OS when devices come
    /// and go), false = None.
    var micEnabled = true

    var isRecording: Bool { recordingStartDate != nil }
    var canRecord: Bool { systemAudioEnabled || micEnabled }

    func startRecording() {
        guard !isRecording, canRecord else { return }
        // Capture engines come later; for now a session is only state.
        recordingStartDate = Date()
    }

    func stopRecording() {
        recordingStartDate = nil
    }
}
