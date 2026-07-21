import CoreAudio
import Foundation

@MainActor
final class RecorderViewModel {
    /// Non-nil while recording; doubles as the session start timestamp that
    /// the elapsed display (and later, file naming) derives from.
    private(set) var recordingStartDate: Date?

    /// System audio selection: true = All Apps (the default), false = None.
    var systemAudioEnabled = true
    /// nil = None. Preselected to the system default input on first refresh.
    var selectedMicID: AudioDeviceID?
    private(set) var mics: [MicDevice] = []
    private var didPreselectMic = false

    var isRecording: Bool { recordingStartDate != nil }
    var canRecord: Bool { systemAudioEnabled || selectedMicID != nil }

    func refreshMics() {
        mics = MicrophoneDeviceProvider.inputDevices()
        if !didPreselectMic {
            didPreselectMic = true
            selectedMicID = MicrophoneDeviceProvider.defaultInputDeviceID()
        }
        // While idle, a vanished device resets the selection to None. While
        // recording that is failover territory — arrives with the capture
        // engine.
        if !isRecording, let id = selectedMicID, !mics.contains(where: { $0.id == id }) {
            selectedMicID = nil
        }
    }

    func startRecording() {
        guard !isRecording, canRecord else { return }
        // Capture engines come later; for now a session is only state.
        recordingStartDate = Date()
    }

    func stopRecording() {
        recordingStartDate = nil
    }
}
