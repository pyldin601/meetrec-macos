import AVFoundation

/// Captures the system default input into an AAC .m4a file at the device's
/// native sample rate and channel count. Capture runs from init until
/// `stop()`.
final class MicCapture {
    /// Called on the main queue when the engine stops on its own — the
    /// captured device disconnected or changed shape. Never called after
    /// `stop()`.
    var onDied: (() -> Void)?

    private let engine = AVAudioEngine()
    private let writer: AudioFileWriter
    private var configObserver: NSObjectProtocol?

    init(url: URL) throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MeetRecError("No usable microphone input device.")
        }
        writer = try AudioFileWriter(url: url, format: format)
        // Taps are delivered on a non-realtime thread, so writing the file
        // here is safe.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [writer] buffer, _ in
            writer.write(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            writer.finalize()
            throw MeetRecError("Could not start the microphone: \(error.localizedDescription)")
        }
        // The engine posts a configuration change when its input device
        // disappears or changes shape; it stops rendering when the device is
        // actually gone. A spurious change can also fire while the engine
        // keeps running — ignore those.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.engine.isRunning else { return }
            self.onDied?()
        }
    }

    /// Stops capture and finalizes the file; a file that captured nothing
    /// is deleted.
    func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        onDied = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer.finalize()
    }
}
