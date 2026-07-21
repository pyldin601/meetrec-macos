import CoreAudio
import Foundation
import ScreenCaptureKit

enum SourceMode: String, CaseIterable, Identifiable {
    case application = "Application"
    case window = "Window"

    var id: String { rawValue }
}

enum CaptureTarget {
    case app(SCRunningApplication)
    case window(SCWindow)

    var processID: pid_t? {
        switch self {
        case .app(let app):
            return app.processID
        case .window(let window):
            return window.owningApplication?.processID
        }
    }

    var displayName: String {
        switch self {
        case .app(let app):
            return app.applicationName
        case .window(let window):
            let appName = window.owningApplication?.applicationName ?? "Unknown"
            let title = window.title ?? ""
            return title.isEmpty ? appName : "\(appName) — \(title)"
        }
    }
}

struct MicDevice: Hashable, Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum RecordingState: Equatable {
    case idle
    case preparing
    case recording(startedAt: Date)
    case stopping
}

struct MeetRecError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
