import Foundation

let RECORDINGS_FOLDER = "MeetRecRecordings"

enum RecordingInput {
  case device
  case system

  var suffix: String {
    switch self {
    case .device: "mic"
    case .system: "system"
    }
  }
}

func getRecordingsDirectoryURL() -> URL {
  let home = FileManager.default.homeDirectoryForCurrentUser
  return home.appendingPathComponent(RECORDINGS_FOLDER)
}

func getRecordingDirectoryURL(date: Date) -> URL {
  let recordings = getRecordingsDirectoryURL()
  let recordingForDate = recordings.appendingPathComponent(stamp(for: date))

  return recordingForDate
}

func getRecordingFileURL(forInput: RecordingInput, withDate date: Date, withOffset offset: UInt64)
  -> URL
{
  let directory = getRecordingDirectoryURL(date: date)
  let filename = "\(stamp(for: date))-\(offset)-\(forInput.suffix)"

  return directory.appendingPathComponent(filename)
}

private func stamp(for date: Date) -> String {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "yyyyMMddHHmmss"
  return formatter.string(from: date)
}
