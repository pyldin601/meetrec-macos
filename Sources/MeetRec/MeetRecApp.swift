import AppKit

@main
@MainActor
enum MeetRecMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let recordingController = RecordingController()

    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let item = !recordingController.isRecording
            ? NSMenuItem(title: "Start Recording", action: #selector(startRecording), keyEquivalent: "")
            : NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        menu.addItem(item)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Recordings Folder", action: #selector(openRecordingsFolder), keyEquivalent: ""))

        return menu
    }

    @objc func startRecording() {
        recordingController.startRecording()
        updateRecordingTimeLabel()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateRecordingTimeLabel()
            }
        }
    }

    @objc func stopRecording() {
        recordingController.stopRecording()

        timer?.invalidate()
        updateRecordingTimeLabel()
    }

    @objc func openRecordingsFolder() {
        NSWorkspace.shared.open(getRecordingsDirectoryURL())
    }

    private func updateRecordingTimeLabel() {
        guard .stopped != recordingController.status else {
            NSApp.dockTile.badgeLabel = nil
            return
        }

        let m = recordingController.recordingTime / 60
        let s = recordingController.recordingTime % 60
        let label = String(format: "%d:%02d", m, s)
        NSApp.dockTile.badgeLabel = label
    }
}
