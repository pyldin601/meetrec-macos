import AVFoundation
import Foundation
import os

/// Streams PCM buffers into an AAC (.m4a) file, converting sample rate,
/// channel count, and layout as needed.
///
/// Thread contract: `write` is only called from a single capture context (the
/// SCStream sample-handler queue, or the AVAudioEngine tap thread).
/// `finalize`/`discardIfEmpty` may be called from elsewhere, but only after
/// capture has fully stopped and no further `write` can occur.
final class AudioFileWriter {
    let url: URL

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
        converter = nil
        file = nil
    }

    /// Rollback path: closes the file and removes it when nothing was written.
    func discardIfEmpty() {
        let isEmpty = framesWritten == 0
        finalize()
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
