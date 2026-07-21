import AppKit
import AVFoundation
import Foundation

enum Permissions {
    static var microphoneDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// System-audio capture (CoreAudio process taps) has no public preflight
    /// API; the permission prompt appears automatically when the first tap is
    /// created, and a denial surfaces as a tap-creation error. This deep links
    /// to the pane where the user can flip the switch afterwards.
    static func openSystemAudioRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
