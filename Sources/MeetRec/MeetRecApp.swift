import AppKit

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
    private let recordingState = RecordingStateStore()
    private var statusItemController: StatusItemController?
    private var logTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement covers the assembled bundle; set the policy explicitly
        // so bare `swift run` is also windowless with no Dock icon.
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController(recordingState: recordingState)
        logTask = Task {
            for await status in recordingState.changes {
                fputs("[recording] \(status)\n", stderr)
            }
        }
    }
}
