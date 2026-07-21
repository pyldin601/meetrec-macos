import CoreAudio
import Foundation

struct AudioApp: Hashable, Identifiable {
    let pid: pid_t
    let name: String
    let bundleID: String?

    var id: pid_t { pid }
}

enum CaptureTarget: Hashable {
    case systemAudio
    case app(AudioApp)

    var displayName: String {
        switch self {
        case .systemAudio:
            return "System audio"
        case .app(let app):
            return app.name
        }
    }

    var pid: pid_t? {
        switch self {
        case .systemAudio:
            return nil
        case .app(let app):
            return app.pid
        }
    }

    var fileSuffix: String {
        switch self {
        case .systemAudio:
            return "system"
        case .app:
            return "app"
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
