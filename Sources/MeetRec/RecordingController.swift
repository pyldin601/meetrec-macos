import AVFoundation

@MainActor
final class RecordingController {
    enum Status: Equatable {
        case started(at: Date)
        case stopped
    }

    private var deviceChangeTask: Task<(), Never>?
    private var deviceRecordingTask: Task<(), Never>?
    private var systemRecordingTask: Task<(), Never>?

    private(set) var status: Status = .stopped

    var isRecording: Bool {
        status != .stopped
    }

    var recordingTime: UInt64 {
        switch status {
        case .stopped: 0
        // Clamp to 0: a backward system clock adjustment would otherwise make
        // this negative and crash the trapping UInt64 conversion.
        case .started(at: let startedAt): UInt64(max(0, startedAt.distance(to: Date())))
        }
    }

    func startRecording() {
        guard status == .stopped else {
            return
        }

        let date = Date()

        createDeviceChangeTask(at: date)
        createSystemRecordingTask(at: date)

        status = .started(at: date)
    }

    func stopRecording() {
        guard case .started(at: _) = status else {
            return
        }

        cancelDeviceChangeTask()
        cancelSystemRecordingTask()

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
                // Clamp to 0: a backward system clock adjustment would otherwise make
                // this negative and crash the trapping UInt64 conversion.
                let intervalMillis = UInt64(max(0, interval * 1000))

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
                withOffset: offset
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

    private func createSystemRecordingTask(at startedAt: Date) {
        cancelSystemRecordingTask()

        systemRecordingTask = Task {
            let directoryURL = getRecordingDirectoryURL(date: startedAt)
            let fileURL = getRecordingFileURL(
                forInput: RecordingInput.system,
                withDate: startedAt,
                withOffset: 0
            )

            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

                let stream = try captureSystemAudio()
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

    private func cancelSystemRecordingTask() {
        systemRecordingTask?.cancel()
        systemRecordingTask = nil
    }
}
