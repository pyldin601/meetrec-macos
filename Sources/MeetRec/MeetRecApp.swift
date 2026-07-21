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
    private let model = RecorderViewModel()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement covers the assembled bundle; set the policy explicitly
        // so bare `swift run` is also windowless with no Dock icon.
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController(model: model)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isRecording else { return .terminateNow }
        // Finalize the recording files before allowing termination.
        Task {
            await model.stopRecording()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
