import AppKit

/// The app's entire UI: a menu bar status item — record icon while idle,
/// stop icon + ticking elapsed time while recording — with a menu to
/// start/stop recording and quit.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let pipeline: RecordingPipeline
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var elapsedTimer: Timer?
    private var observeTask: Task<Void, Never>?

    init(pipeline: RecordingPipeline) {
        self.pipeline = pipeline
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        observeTask = Task { [weak self] in
            guard let self else { return }
            for await status in pipeline.changes {
                self.apply(status)
            }
        }
    }

    // MARK: - Menu

    /// Rebuilt on every open: the title depends on current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let isStarted = pipeline.status.startedAt != nil
        let toggle = NSMenuItem(
            title: isStarted ? "Stop Recording" : "Start Recording",
            action: #selector(toggleRecording),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        // Our own selector, not NSApplication.terminate(_:) — macOS 26 auto-
        // decorates well-known actions with icons, and Quit should have none.
        let quit = NSMenuItem(title: "Quit MeetRec", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func toggleRecording() {
        if pipeline.status.startedAt != nil {
            pipeline.stop()
        } else {
            pipeline.start()
        }
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    // MARK: - Status item button

    private func apply(_ status: RecordingPipeline.Status) {
        updateButton(startedAt: status.startedAt)
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        guard let startedAt = status.startedAt else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateButton(startedAt: startedAt) }
        }
        // .common keeps the clock ticking while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func updateButton(startedAt: Date?) {
        guard let button = statusItem.button else { return }
        if let startedAt {
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
