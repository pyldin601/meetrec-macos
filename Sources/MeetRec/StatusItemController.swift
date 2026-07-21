import AppKit

/// The app's entire UI: a menu bar status item — record icon while idle,
/// stop icon + ticking elapsed time while recording — with a menu to
/// start/stop recording and quit.
@MainActor
final class StatusItemController: NSObject {
    private let model: RecorderViewModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let toggleItem: NSMenuItem
    private var elapsedTimer: Timer?

    init(model: RecorderViewModel) {
        self.model = model
        self.toggleItem = NSMenuItem(title: "", action: #selector(toggleRecording), keyEquivalent: "")
        super.init()
        toggleItem.target = self

        let menu = NSMenu()
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        // Our own selector, not NSApplication.terminate(_:) — macOS 26 auto-
        // decorates well-known actions with icons, and Quit should have none.
        let quit = NSMenuItem(title: "Quit MeetRec", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        refresh()
    }

    @objc private func toggleRecording() {
        if model.isRecording { model.stopRecording() } else { model.startRecording() }
        refresh()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    /// Single UI sync point. State only changes through the menu for now, so
    /// calling this after each action suffices; model observation arrives
    /// when state starts changing from outside (device loss, failures).
    private func refresh() {
        toggleItem.title = model.isRecording ? "Stop Recording" : "Start Recording"
        updateButton()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if model.isRecording {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateButton() }
            }
            // .common keeps the clock ticking while the menu is open.
            RunLoop.main.add(timer, forMode: .common)
            elapsedTimer = timer
        }
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        if let startedAt = model.recordingStartDate {
            button.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: "MeetRec — recording")
            button.attributedTitle = NSAttributedString(
                string: " " + Self.elapsedString(Int(max(0, Date().timeIntervalSince(startedAt)))),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)]
            )
            button.imagePosition = .imageLeft
        } else {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "MeetRec — idle")
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    static func elapsedString(_ seconds: Int) -> String {
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
