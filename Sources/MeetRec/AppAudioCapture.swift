import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures the audio of one application or window with ScreenCaptureKit and
/// streams it into an AudioFileWriter.
final class AppAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    private let audioQueue = DispatchQueue(label: "dev.roman.MeetRec.scstream-audio")
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var writer: AudioFileWriter?
    private var onStopped: ((String) -> Void)?
    private var stoppedIntentionally = false

    func start(
        target: CaptureTarget,
        display: SCDisplay?,
        writer: AudioFileWriter,
        onStopped: @escaping (String) -> Void
    ) async throws {
        self.writer = writer
        self.onStopped = onStopped

        let filter: SCContentFilter
        switch target {
        case .app(let app):
            guard let display else {
                throw MeetRecError("No display is available for application capture.")
            }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // Audio-focused capture: shrink the mandatory video side to a minimum.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        stateLock.lock()
        stoppedIntentionally = true
        stateLock.unlock()
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
        }
        // Drain in-flight audio callbacks so the writer can be finalized from
        // another context without racing a write.
        audioQueue.sync { }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        let sampleCount = sampleBuffer.numSamples
        guard sampleCount > 0, let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            return
        }
        pcm.frameLength = AVAudioFrameCount(sampleCount)
        do {
            try sampleBuffer.copyPCMData(fromRange: 0..<sampleCount, into: pcm.mutableAudioBufferList)
        } catch {
            return
        }
        writer?.write(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        let wasIntentional = stoppedIntentionally
        stateLock.unlock()
        guard !wasIntentional else { return }
        // Fires when the captured window closes or capture fails; an
        // intentional stopCapture() does not land here.
        onStopped?("Capture stopped: \(error.localizedDescription)")
    }
}
