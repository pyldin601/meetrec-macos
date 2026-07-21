import AppKit
import CoreAudio

/// The app's entire UI: a menu bar status item — record icon while idle,
/// stop icon + ticking elapsed time while recording — with a menu to
/// start/stop recording, pick the audio sources, and quit.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: RecorderViewModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var elapsedTimer: Timer?

    init(model: RecorderViewModel) {
        self.model = model
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refresh()
    }

    // MARK: - Menu

    /// Rebuilt on every open: the device list, checkmarks, titles, and
    /// enabling all depend on current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refreshMics()
        menu.removeAllItems()

        let toggle = NSMenuItem(
            title: model.isRecording ? "Stop Recording" : "Start Recording",
            action: #selector(toggleRecording),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.isEnabled = model.isRecording || model.canRecord
        menu.addItem(toggle)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "System Audio"))
        addSourceItem("All Apps", checked: model.systemAudioEnabled, action: #selector(selectAllApps))
        addSourceItem("None", checked: !model.systemAudioEnabled, action: #selector(selectNoSystemAudio))

        menu.addItem(.sectionHeader(title: "Microphone"))
        for mic in model.mics {
            addSourceItem(mic.name, checked: model.selectedMicID == mic.id, action: #selector(selectMic(_:)))
                .representedObject = mic.id
        }
        addSourceItem("None", checked: model.selectedMicID == nil, action: #selector(selectNoMic))

        menu.addItem(.separator())
        // Our own selector, not NSApplication.terminate(_:) — macOS 26 auto-
        // decorates well-known actions with icons, and Quit should have none.
        let quit = NSMenuItem(title: "Quit MeetRec", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Sources are frozen while recording; switching mid-session arrives
    /// with the capture engine.
    @discardableResult
    private func addSourceItem(_ title: String, checked: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        item.isEnabled = !model.isRecording
        menu.addItem(item)
        return item
    }

    // MARK: - Actions

    @objc private func toggleRecording() {
        if model.isRecording { model.stopRecording() } else { model.startRecording() }
        refresh()
    }

    @objc private func selectAllApps() {
        model.systemAudioEnabled = true
    }

    @objc private func selectNoSystemAudio() {
        model.systemAudioEnabled = false
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? AudioDeviceID else { return }
        model.selectedMicID = id
    }

    @objc private func selectNoMic() {
        model.selectedMicID = nil
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    // MARK: - Status item button

    /// Single UI sync point. State only changes through the menu for now, so
    /// calling this after each action suffices; model observation arrives
    /// when state starts changing from outside (device loss, failures).
    private func refresh() {
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
