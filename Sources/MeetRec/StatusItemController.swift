import AppKit
import CoreAudio
import Observation

/// The app's entire UI: a menu bar status item whose icon reflects the
/// recording state (record icon while idle, stop icon + elapsed time while
/// recording) and a menu for starting/stopping and picking sources. Errors
/// surface as standard alerts — the app has no windows.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: RecorderViewModel
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var elapsedTimer: Timer?
    private var pendingAlerts: [String] = []
    private var isPresentingAlerts = false

    init(model: RecorderViewModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateButton()
        observeModel()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refreshMics()
        menu.removeAllItems()

        let toggle: NSMenuItem
        switch model.state {
        case .idle, .preparing:
            toggle = NSMenuItem(title: "Start Recording", action: #selector(startRecording), keyEquivalent: "")
            toggle.isEnabled = model.canRecord
        case .recording, .stopping:
            toggle = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
            toggle.isEnabled = model.isRecording
        }
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        let idle = model.state == .idle
        let systemItem = NSMenuItem(title: "System Audio", action: nil, keyEquivalent: "")
        systemItem.submenu = systemAudioSubmenu()
        systemItem.isEnabled = idle
        menu.addItem(systemItem)

        // Unlike System Audio, the mic stays switchable mid-recording — each
        // change continues into a new segment file (SPEC.md §1.3).
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micItem.submenu = microphoneSubmenu()
        micItem.isEnabled = idle || model.isRecording
        menu.addItem(micItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MeetRec", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// All Apps / None only — the engine supports per-app taps, but per-app
    /// selection is deliberately not exposed here (SPEC.md §6).
    private func systemAudioSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let allApps = NSMenuItem(title: "All Apps", action: #selector(selectSystemAudio), keyEquivalent: "")
        allApps.target = self
        allApps.state = model.selectedTarget == .systemAudio ? .on : .off
        submenu.addItem(allApps)

        let none = NSMenuItem(title: "None", action: #selector(selectNoSystemAudio), keyEquivalent: "")
        none.target = self
        none.state = model.selectedTarget == nil ? .on : .off
        submenu.addItem(none)

        return submenu
    }

    private func microphoneSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        for mic in model.mics {
            let item = NSMenuItem(title: mic.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: mic.id)
            item.state = model.selectedMicID == mic.id ? .on : .off
            submenu.addItem(item)
        }

        let none = NSMenuItem(title: "None", action: #selector(selectNoMicrophone), keyEquivalent: "")
        none.target = self
        none.state = model.selectedMicID == nil ? .on : .off
        none.isEnabled = !model.isMicSoleActiveSource
        submenu.addItem(none)

        return submenu
    }

    // MARK: - Actions

    @objc private func startRecording() {
        Task { await model.startRecording() }
    }

    @objc private func stopRecording() {
        Task { await model.stopRecording() }
    }

    @objc private func selectSystemAudio() {
        guard model.state == .idle else { return }
        model.selectedTarget = .systemAudio
    }

    @objc private func selectNoSystemAudio() {
        guard model.state == .idle else { return }
        model.selectedTarget = nil
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        let id = AudioDeviceID(number.uint32Value)
        Task { await model.selectMic(id) }
    }

    @objc private func selectNoMicrophone() {
        Task { await model.selectMic(nil) }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Status item button

    private func updateButton() {
        guard let button = statusItem.button else { return }
        if let startedAt = model.recordingStartDate {
            button.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: "MeetRec — recording")
            let seconds = Int(max(0, Date().timeIntervalSince(startedAt)))
            button.attributedTitle = NSAttributedString(
                string: " " + Self.elapsedString(seconds),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)]
            )
            button.imagePosition = .imageLeft
        } else {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "MeetRec — idle")
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    private func syncElapsedTimer() {
        if model.isRecording {
            guard elapsedTimer == nil else { return }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                // Fires on the main run loop; updating directly (no actor hop
                // through the main queue) keeps the clock ticking while the
                // menu is open, when the run loop is in event-tracking mode.
                MainActor.assumeIsolated { self?.updateButton() }
            }
            RunLoop.main.add(timer, forMode: .common)
            elapsedTimer = timer
        } else {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
        }
    }

    static func elapsedString(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    // MARK: - Model observation

    private func observeModel() {
        withObservationTracking {
            _ = model.state
            _ = model.lastError
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeModel()
                self.updateButton()
                self.syncElapsedTimer()
                self.presentPendingError()
            }
        }
    }

    private func presentPendingError() {
        if let message = model.lastError {
            model.lastError = nil
            pendingAlerts.append(message)
        }
        // runModal drains the main queue, so another error can be observed
        // while an alert is up; queue it instead of nesting modal sessions.
        guard !isPresentingAlerts else { return }
        isPresentingAlerts = true
        defer { isPresentingAlerts = false }
        while !pendingAlerts.isEmpty {
            presentAlert(pendingAlerts.removeFirst())
        }
    }

    private func presentAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Recording Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        let offersSettings = message.contains("System Settings")
        if offersSettings {
            alert.addButton(withTitle: "Open System Settings")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn, offersSettings {
            if message.contains("Microphone") {
                Permissions.openMicrophoneSettings()
            } else {
                Permissions.openSystemAudioRecordingSettings()
            }
        }
    }
}
