import AVFoundation

/// Captures the system default input into an AAC .m4a file at the device's
/// native sample rate and channel count. Capture runs from init until
/// `stop()`.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?

    init(url: URL) throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MeetRecError("No usable microphone input device.")
        }
        file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: format.channelCount == 1 ? 96_000 : 160_000,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        // Taps are delivered on a non-realtime thread, so writing the file
        // here is safe. The lock covers the race with stop(): AVAudioEngine
        // does not guarantee an in-flight tap block has drained when stop()
        // returns.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.write(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            file = nil
            try? FileManager.default.removeItem(at: url)
            throw MeetRecError("Could not start the microphone: \(error.localizedDescription)")
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        try? file?.write(from: buffer)
    }

    /// Stops capture and finalizes the file (the M4A header is written when
    /// the AVAudioFile is released).
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        file = nil
        lock.unlock()
    }
}
