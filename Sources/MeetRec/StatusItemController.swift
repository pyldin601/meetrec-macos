import AppKit

/// The app's entire UI: a menu bar status item and its menu. Skeleton for
/// now — a record icon whose menu holds a single Quit entry.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.autoenablesItems = false
        let quit = NSMenuItem(title: "Quit MeetRec", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        statusItem.button?.image = NSImage(
            systemSymbolName: "record.circle",
            accessibilityDescription: "MeetRec — idle"
        )
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
