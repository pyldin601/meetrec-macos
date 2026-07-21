import Foundation
import ScreenCaptureKit

struct ShareableContent {
    var display: SCDisplay?
    var apps: [SCRunningApplication]
    var windows: [SCWindow]
}

enum ShareableContentProvider {
    /// Lists the applications and windows whose audio can be captured.
    /// Throws when Screen Recording permission is missing.
    static func fetch() async throws -> ShareableContent {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        let apps = content.applications
            .filter { $0.processID != ownPID && !$0.applicationName.isEmpty }
            .sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }

        let windows = content.windows
            .filter { window in
                guard window.owningApplication?.processID != ownPID else { return false }
                guard window.windowLayer == 0 else { return false }
                guard let title = window.title, !title.isEmpty else { return false }
                return window.frame.width >= 100 && window.frame.height >= 100
            }
            .sorted { lhs, rhs in
                let lhsApp = lhs.owningApplication?.applicationName ?? ""
                let rhsApp = rhs.owningApplication?.applicationName ?? ""
                if lhsApp != rhsApp {
                    return lhsApp.localizedCaseInsensitiveCompare(rhsApp) == .orderedAscending
                }
                return (lhs.title ?? "") < (rhs.title ?? "")
            }

        return ShareableContent(display: content.displays.first, apps: apps, windows: windows)
    }
}
