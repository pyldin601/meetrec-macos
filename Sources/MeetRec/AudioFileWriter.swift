import AVFoundation
import Foundation
import os

/// Streams PCM buffers into an AAC (.m4a) file, converting sample rate,
/// channel count, and layout as needed.
///
/// Thread contract: `write` is called from a single capture context (the
/// process-tap IO queue, or the AVAudioEngine tap thread) and may race
/// `finalize`/`discardIfEmpty` from another thread — AVAudioEngine does not
/// guarantee that stopping drains an in-flight tap block, and mic segments
/// now end mid-recording (failover, manual switch). An internal lock
/// serializes them: a `write` that loses the race with `finalize` is a no-op.
final class AudioFileWriter {
    let url: URL

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var framesWritten: Int64 = 0
    private let logger = Logger(subsystem: "dev.roman.MeetRec", category: "AudioFileWriter")

    init(url: URL, channels: AVAudioChannelCount) throws {
        self.url = url
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
        ]
        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, buffer.frameLength > 0 else { return }
        if buffer.format == file.processingFormat {
            do {
                try file.write(from: buffer)
                framesWritten += Int64(buffer.frameLength)
            } catch {
                logger.error("write failed: \(error.localizedDescription)")
            }
            return
        }
        writeConverting(buffer, to: file)
    }

    /// Closes the file. The M4A header is finalized when the AVAudioFile is
    /// released (macOS 14 has no explicit close()).
    func finalize() {
        lock.lock()
        defer { lock.unlock() }
        converter = nil
        file = nil
    }

    /// Closes the file and removes it when nothing was written. Used for
    /// start-failure rollback and for mic segments that end mid-recording.
    func discardIfEmpty() {
        lock.lock()
        let isEmpty = framesWritten == 0
        converter = nil
        file = nil
        lock.unlock()
        if isEmpty {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func writeConverting(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile) {
        let outputFormat = file.processingFormat
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else {
            logger.error("no converter from \(String(describing: buffer.format)) to \(String(describing: outputFormat))")
            return
        }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var conversionError: NSError?
        // Streaming conversion: hand over this buffer once, then report
        // .noDataNow (not .endOfStream, which would finalize the converter).
        converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError {
            logger.error("conversion failed: \(conversionError.localizedDescription)")
            return
        }
        guard output.frameLength > 0 else { return }
        do {
            try file.write(from: output)
            framesWritten += Int64(output.frameLength)
        } catch {
            logger.error("write failed: \(error.localizedDescription)")
        }
    }
}
