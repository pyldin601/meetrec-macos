import AVFoundation
import CoreAudio

enum CaptureEvent {
    case opened(AVAudioFormat)
    case bytes([UInt8])
    case closed(Error?)
}

struct CaptureError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Captures raw audio bytes from the given input device until the returned
/// stream stops being iterated (or the device fails).
///
/// `.opened` carries the negotiated format — sample rate, channel count, and
/// whether samples are interleaved or one buffer per channel — needed to
/// interpret the raw bytes in `.bytes`. `.closed` is always the last event:
/// `nil` for a normal stop (the consumer stopped iterating), an `Error` if
/// the device disconnected or changed configuration mid-capture.
func captureFromDevice(_ deviceID: AudioDeviceID) throws -> AsyncStream<CaptureEvent> {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    guard let audioUnit = input.audioUnit else {
        throw CaptureError("The microphone engine did not provide an input audio unit.")
    }

    var device = deviceID
    let selectStatus = AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &device,
        UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    guard selectStatus == noErr else {
        throw CaptureError("Could not select the microphone (CoreAudio error \(selectStatus)).")
    }

    let format = input.inputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
        throw CaptureError("The selected microphone has no usable input format.")
    }

    // A stalled consumer queues at most this many events (~1 min at a
    // 4096-frame/48kHz cadence) before the oldest are dropped, so a slow
    // reader can't grow this unboundedly.
    let (stream, continuation) = AsyncStream.makeStream(
        of: CaptureEvent.self,
        bufferingPolicy: .bufferingNewest(2800)
    )

    // Taps are delivered on a non-realtime internal thread, not the audio
    // render thread, so yielding here is safe.
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        continuation.yield(.bytes(rawBytes(of: buffer)))
    }

    engine.prepare()
    do {
        try engine.start()
    } catch {
        input.removeTap(onBus: 0)
        continuation.finish()
        throw CaptureError("Could not start the microphone: \(error.localizedDescription)")
    }

    continuation.yield(.opened(format))

    // The engine posts this when its input device disconnects or changes
    // shape; it actually stops rendering only when the device is really
    // gone. A spurious notification can also fire while the engine keeps
    // running (notably right after start, when pinned to a non-default
    // device) — ignore those.
    let configObserver = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange,
        object: engine,
        queue: .main
    ) { _ in
        guard !engine.isRunning else { return }
        continuation.yield(.closed(CaptureError("The microphone was disconnected or its configuration changed.")))
        continuation.finish()
    }

    // Fires once, however the stream ends: the consumer stops iterating
    // (cancelled task, break), or the config-change observer above calls
    // finish() itself. Can run on any thread; hop to main since
    // AVAudioEngine isn't thread-safe. These teardown calls are all safe
    // no-ops if something is already stopped/removed.
    continuation.onTermination = { _ in
        Task { @MainActor in
            NotificationCenter.default.removeObserver(configObserver)
            input.removeTap(onBus: 0)
            engine.stop()
        }
    }

    return stream
}

private func rawBytes(of buffer: AVAudioPCMBuffer) -> [UInt8] {
    var bytes: [UInt8] = []
    for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
        guard let data = audioBuffer.mData else { continue }
        bytes.append(contentsOf: UnsafeRawBufferPointer(start: data, count: Int(audioBuffer.mDataByteSize)))
    }
    return bytes
}
