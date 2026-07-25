import UserNotifications

/// Posts a user-visible notification for a recording failure. Printing to
/// stderr (the previous approach) is invisible for a Dock-icon app with no
/// console attached, so a failed capture looked identical to a working one.
func notifyRecordingFailure(_ error: Error, for input: RecordingInput) {
    let content = UNMutableNotificationContent()
    content.title = "MeetRec"
    content.body = "Could not record \(input.displayName): \(error.localizedDescription)"
    content.sound = .default

    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
}
