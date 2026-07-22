import AVFoundation
import CoreAudio
import Foundation

/// Owns the whole recording lifecycle: current status, the default input
/// device lookup, mic capture, and writing captured audio to disk.
///
/// `changes` is multicast: every access returns an independent stream that
/// yields the current status first, then every transition.
@MainActor
final class RecordingPipeline {
    enum Status: Equatable {
        case stopped
        case started(at: Date)

        var startedAt: Date? {
            if case .started(let date) = self { return date }
            return nil
        }
    }

    private(set) var status: Status = .stopped
    private var subscribers: [UUID: AsyncStream<Status>.Continuation] = [:]
    private var captureTask: Task<Void, Never>?

    var changes: AsyncStream<Status> {
        let (stream, continuation) = AsyncStream.makeStream(of: Status.self)
        let id = UUID()
        continuation.yield(status)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[id] = nil }
        }
        return stream
    }

    /// No-op if already recording, or if there's no usable input device.
    func start() {
        guard status == .stopped, let deviceID = defaultInputDeviceID(), let stream = try? captureFromDevice(deviceID) else {
            return
        }
        transition(to: .started(at: Date()))
        captureTask = Task {
            var writer: AudioFileWriter?
            var format: AVAudioFormat?
            for await event in stream {
                switch event {
                case .opened(let openedFormat):
                    format = openedFormat
                    let url = recordingsDirectory().appendingPathComponent("\(stamp(for: Date()))-mic.m4a")
                    writer = try? AudioFileWriter(url: url, format: openedFormat)
                case .bytes(let chunk, _):
                    if let format {
                        writer?.write(chunk, format: format)
                    }
                case .closed:
                    writer?.finalize()
                    writer = nil
                    format = nil
                }
            }
            writer?.finalize()
        }
    }

    /// No-op if not recording.
    func stop() {
        guard status != .stopped else { return }
        captureTask?.cancel()
        captureTask = nil
        transition(to: .stopped)
    }

    private func transition(to new: Status) {
        status = new
        for subscriber in subscribers.values {
            subscriber.yield(new)
        }
    }
}

private func recordingsDirectory() -> URL {
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("MeetRecRecordings")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func stamp(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMddHHmmss"
    return formatter.string(from: date)
}
