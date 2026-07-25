import AVFoundation
import Logging

// Create a logger
let logger = Logger(label: "xyz.pyldin601.MeetRec.AudioFileWriter")

/// Writes captured audio bytes to an AAC (.m4a) file.
final class AudioFileWriter {
    let url: URL

    private var file: AVAudioFile?
    private var wroteFrames = false

    init(url: URL, format: AVAudioFormat) throws {
        self.url = url.appendingPathExtension("m4a")
        file = try AVAudioFile(
            forWriting: self.url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: format.channelCount == 1 ? 96_000 : 160_000,
            ],
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        logger.info("File created", metadata: ["file": "\(self.url)"]);
    }

    /// Writes one chunk of raw bytes, as captured in `format` (the format
    /// from this source's `.opened` event).
    func write(_ bytes: [UInt8], format: AVAudioFormat) {
        guard let file, let buffer = pcmBuffer(from: bytes, format: format) else { return }
        do {
            try file.write(from: buffer)
            logger.debug("Bytes written", metadata: ["len": "\(bytes.count)"])
            wroteFrames = true
        } catch {
            // Best-effort: one bad chunk shouldn't end the whole recording.
        }
    }

    /// Same cleanup as `finalize()`, so a writer that's just dropped (e.g.
    /// replaced by a new one on a device switch) without an explicit
    /// finalize() call still doesn't leave an empty file behind.
    deinit {
        logger.info("Finalizing file", metadata: ["file": "\(self.url)"])
        deleteIfEmpty()
    }

    private func deleteIfEmpty() {
        guard !wroteFrames else { return }
        try? FileManager.default.removeItem(at: url)
        logger.info("Empty file deleted", metadata: ["file": "\(self.url)"]);
    }
}

/// Rebuilds a PCM buffer from bytes produced by `rawBytes(of:)` in
/// AudioCapture.swift — the inverse operation, so this only works for bytes
/// that came from there. Handles both interleaved and non-interleaved
/// formats: for non-interleaved, `mBytesPerFrame` describes one channel's
/// buffer, so the total per-frame size is that times the channel count.
private func pcmBuffer(from bytes: [UInt8], format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let asbd = format.streamDescription.pointee
    let bufferCount = format.isInterleaved ? 1 : Int(asbd.mChannelsPerFrame)
    let bytesPerFrame = Int(asbd.mBytesPerFrame) * bufferCount
    guard bytesPerFrame > 0 else { return nil }
    let frameCount = AVAudioFrameCount(bytes.count / bytesPerFrame)
    guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        return nil
    }
    buffer.frameLength = frameCount
    bytes.withUnsafeBytes { raw in
        var offset = 0
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let dest = audioBuffer.mData else { continue }
            let byteCount = Int(audioBuffer.mDataByteSize)
            memcpy(dest, raw.baseAddress!.advanced(by: offset), byteCount)
            offset += byteCount
        }
    }
    return buffer
}
