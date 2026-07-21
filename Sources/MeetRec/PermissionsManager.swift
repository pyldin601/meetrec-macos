import AppKit
import AVFoundation
import CoreGraphics
import Foundation

enum Permissions {
    static var microphoneDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var screenCaptureGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Registers the app in the Screen Recording privacy list and shows the
    /// system prompt the first time it is ever called for this app. Granting
    /// the permission only takes effect after the app is relaunched.
    @discardableResult
    static func requestScreenCaptureAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
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
