import AppKit
import AVFoundation
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

            var writer: AudioFileWriter?
            var format: AVAudioFormat?
            for await event in audioDeviceEventStream {
                switch event {
                case .opened(let openedFormat):
                    format = openedFormat
                    let url = recordingsDirectory().appendingPathComponent("\(stamp(for: Date()))-mic.m4a")
                    writer = try? AudioFileWriter(url: url, format: openedFormat)
                case .bytes(let chunk, _):
                    if let format {
                        writer?.write(chunk, format: format)
                    }
                case .closed(let error):
                    writer?.finalize()
                    writer = nil
                    format = nil
                }
            }
            writer?.finalize()
        }
    }
}

private func recordingsDirectory() -> URL {
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("MeetRecRecordings")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func stamp(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMddHHmmss"
    return formatter.string(from: date)
}
