import AVFoundation

@MainActor
final class RecordingController {
    enum Status: Equatable {
        case started(at: Date)
        case stopped
    }

    private var deviceChangeTask: Task<(), Never>?
    private var deviceRecordingTask: Task<(), Never>?

    private(set) var status: Status = .stopped

    var isRecording: Bool {
        status != .stopped
    }

    func toggle() {
        switch status {
        case .started:
            stopRecording()
        case .stopped:
            startRecording()
        }
    }

    func startRecording() {
        guard status == .stopped else {
            return
        }

        let date = Date()

        createDeviceChangeTask(at: date)

        status = .started(at: date)
    }

    func stopRecording() {
        guard case .started(at: _) = status else {
            return
        }

        deviceChangeTask?.cancel()

        status = .stopped
    }

    private func createDeviceChangeTask(at startedAt: Date)  {
        cancelDeviceChangeTask()

        deviceChangeTask = Task {
            for await deviceID in defaultInputDeviceIDs() {
                cancelDeviceRecordingTask()

                guard let deviceID else {
                    // Can't find default input device
                    continue
                }

                let interval = startedAt.distance(to: Date())
                let intervalMillis = UInt64(interval * 1000)

                createDeviceRecordingTask(at: startedAt, forDeviceID: deviceID, forOffset: intervalMillis)
            }

            cancelDeviceRecordingTask()
        }
    }

    private func cancelDeviceChangeTask() {
        deviceChangeTask?.cancel()
        deviceChangeTask = nil
    }

    private func createDeviceRecordingTask(at startedAt: Date, forDeviceID deviceID: AudioDeviceID, forOffset offset: UInt64) {
        deviceRecordingTask?.cancel()

        deviceRecordingTask = Task {
            let directoryURL = getRecordingDirectoryURL(date: startedAt)
            let fileURL = getRecordingFileURL(
                forInput: RecordingInput.device,
                withDate: startedAt,
                withOffset: offset,
            )

            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

                let stream = try captureFromDevice(deviceID)
                var writer: AudioFileWriter?
                var format: AVAudioFormat?

                for await event in stream {
                    switch event {
                    case .opened(let openedFormat):
                        format = openedFormat
                        writer = try AudioFileWriter(url: fileURL, format: openedFormat)

                    case .bytes(let chunk, _):
                        if let format {
                            writer?.write(chunk, format: format)
                        }

                    case .closed:
                        writer = nil
                        format = nil
                    }
                }
                writer = nil
            } catch {
                print("Failed to create recording task", error)
            }
        }
    }

    private func cancelDeviceRecordingTask() {
        deviceRecordingTask?.cancel()
        deviceRecordingTask = nil
    }
}
