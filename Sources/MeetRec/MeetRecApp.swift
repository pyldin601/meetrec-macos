import AppKit
import CoreAudio

@main
@MainActor
enum MeetRecMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let recordingState = RecordingStatusStore()
    private let defaultInputDevice = DefaultInputDeviceStore()
    private var statusItemController: StatusItemController?
    private var deviceLogTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement covers the assembled bundle; set the policy explicitly
        // so bare `swift run` is also windowless with no Dock icon.
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController(recordingState: recordingState)
        // switchMap: only logs while recording is active, switching to the
        // idle stream (and cancelling the prior one) on every status change.
        deviceLogTask = Task {
            let loggedWhileRecording = recordingState.changes.flatMapLatest { status in
                status == .stopped
                    ? AsyncStream<AudioDeviceID?> { $0.finish() }
                    : self.defaultInputDevice.changes
            }
            for await deviceID in loggedWhileRecording {
                fputs("[default-input] \(deviceID.map { "\($0)" } ?? "none")\n", stderr)
            }
        }
    }
}
