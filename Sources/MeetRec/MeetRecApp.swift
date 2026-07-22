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
        // switchMap: only captures while recording is active, switching to
        // the idle stream (and cancelling the prior one) on every status
        // change. Switching devices mid-recording works the same way — a
        // new deviceID cancels the inner task iterating the previous
        // device's stream, which tears down its engine via onTermination.
        // No explicit "stop the old capture" bookkeeping needed here.
        deviceLogTask = Task {
            let recordingStateStream: AsyncStream<RecordingStatusStore.Status> = recordingState.changes
            let audioDeviceIDStream: AsyncStream<AudioDeviceID?> = recordingStateStream.flatMapLatest { status in
                status == .stopped
                    ? AsyncStream<AudioDeviceID?> { $0.finish() }
                    : self.defaultInputDevice.changes
            }
            let audioDeviceEventStream: AsyncStream<CaptureEvent> = audioDeviceIDStream.flatMapLatest { deviceID in
                guard let deviceID else {
                    return AsyncStream<CaptureEvent> { $0.finish() }
                }
                do {
                    return try captureFromDevice(deviceID)
                } catch {
                    return AsyncStream<CaptureEvent> { $0.finish() }
                }
            }

            for await event in audioDeviceEventStream {
                switch event {
                case .opened(let format):
                    fputs("[capture] opened: \(format)\n", stderr)
                case .bytes(let chunk):
                    fputs("[bytes] \(chunk.count)\n", stderr)
                case .closed(let error):
                    fputs("[capture] closed: \(error?.localizedDescription ?? "nil")\n", stderr)
                }
            }
        }
    }
}
