import AVFoundation

/// Streams PCM buffers into an AAC .m4a file. The file takes the capture
/// format's sample rate, channel count, and layout, so buffers are written
/// without conversion.
///
/// Thread contract: `write` is called from a single capture thread and may
/// race `finalize` from another — neither AVAudioEngine nor CoreAudio
/// guarantees in-flight callbacks have drained when capture stops. The lock
/// serializes them; a `write` that loses the race is a no-op.
final class AudioFileWriter {
    let url: URL

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var wroteFrames = false

    init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: format.channelCount == 1 ? 96_000 : 160_000,
            ],
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, buffer.frameLength > 0 else { return }
        try? file.write(from: buffer)
        wroteFrames = true
    }

    /// Finalizes the file (the M4A header is written when the AVAudioFile is
    /// released). A file that captured nothing is deleted.
    func finalize() {
        lock.lock()
        file = nil
        let wrote = wroteFrames
        lock.unlock()
        if !wrote {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
