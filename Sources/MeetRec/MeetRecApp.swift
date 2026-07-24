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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement covers the assembled bundle; set the policy explicitly
        // so bare `swift run` is also windowless with no Dock icon.
//        NSApp.setActivationPolicy(.accessory)
//        statusItemController = StatusItemController(pipeline: pipeline, controller: controller)
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

        return menu
    }

    @objc func startRecording() {
        recordingController.startRecording()
    }

    @objc func stopRecording() {
        recordingController.stopRecording()
    }
}
