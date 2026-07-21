import Foundation

@MainActor
final class RecorderViewModel {
    /// Non-nil while recording; doubles as the session start timestamp that
    /// the elapsed display (and later, file naming) derives from.
    private(set) var recordingStartDate: Date?

    var isRecording: Bool { recordingStartDate != nil }

    func startRecording() {
        guard !isRecording else { return }
        // Capture engines come later; for now a session is only state.
        recordingStartDate = Date()
    }

    func stopRecording() {
        recordingStartDate = nil
    }
}
