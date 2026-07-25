import AudioToolbox
import AVFoundation
import CoreAudio

/// Prompts for both recording permissions up front, so the first "Start
/// Recording" click isn't racing a permission dialog the user hasn't
/// answered yet. Both calls are no-ops once a choice has been made — a
/// denial is not surfaced here, since the capture path already reports it
/// per-source when a recording actually fails.
func requestRecordingPermissions() {
    AVCaptureDevice.requestAccess(for: .audio) { _ in }
    // Off the main thread: creating a tap is a synchronous HAL call, and
    // this runs during app launch.
    DispatchQueue.global().async { requestSystemAudioPermission() }
}

/// There is no check/request API for the "System Audio Recording Only"
/// permission — creating a process tap is what triggers the prompt, so
/// make a throwaway one and destroy it immediately.
private func requestSystemAudioPermission() {
    let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    description.name = "MeetRec Permission Check"
    description.isPrivate = true
    description.muteBehavior = .unmuted

    var tapID = AudioObjectID(kAudioObjectUnknown)
    guard AudioHardwareCreateProcessTap(description, &tapID) == noErr,
          tapID != kAudioObjectUnknown
    else { return }
    AudioHardwareDestroyProcessTap(tapID)
}
