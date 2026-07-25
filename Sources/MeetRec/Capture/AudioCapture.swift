import AudioToolbox
import AVFoundation
import CoreAudio

enum CaptureEvent {
    case opened(AVAudioFormat)
    /// `pts` is microseconds since the system's mach absolute-time epoch —
    /// the clock both capture functions share, so timestamps from
    /// `captureFromDevice` and `captureSystemAudio` are directly comparable.
    case bytes(data: [UInt8], pts: UInt64)
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
/// interpret the raw bytes in `.bytes`. Each `.bytes` chunk carries its
/// presentation time, so a consumer can detect gaps instead of assuming
/// delivery is continuous. `.closed` is always the last event: `nil` for a
/// normal stop (the consumer stopped iterating), an `Error` if the device
/// disconnected or changed configuration mid-capture.
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

    let (stream, continuation) = AsyncStream.makeStream(
        of: CaptureEvent.self,
        bufferingPolicy: .unbounded
    )

    // Taps are delivered on a non-realtime internal thread, not the audio
    // render thread, so yielding here is safe.
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
        let hostTime = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
        continuation.yield(.bytes(data: rawBytes(of: buffer), pts: microseconds(fromHostTime: hostTime)))
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

private let hostTimebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

/// Converts a `mach_absolute_time`-based host time (as delivered by
/// `AVAudioTime`/`AudioTimeStamp`) to microseconds since the same mach
/// epoch, so callers never need to know about `mach_timebase_info`.
private func microseconds(fromHostTime hostTime: UInt64) -> UInt64 {
    hostTime * UInt64(hostTimebase.numer) / UInt64(hostTimebase.denom) / 1000
}

/// Captures the system audio mix (excluding this process's own output) via
/// a CoreAudio process tap, until the returned stream stops being iterated.
///
/// Unlike `captureFromDevice`, this needs only the "System Audio Recording
/// Only" permission — never Screen Recording — and the grant takes effect
/// without relaunching the app.
///
/// `.bytes` only reflects what the tap actually delivers. What that is
/// during system-wide silence isn't reliably specified (zeroed buffers,
/// empty buffers, or nothing at all, depending on OS/device state) — no
/// gap-filling is done here, so the stream is not guaranteed wall-clock
/// continuous. Each chunk's `pts` lets a consumer detect such gaps itself.
func captureSystemAudio() throws -> AsyncStream<CaptureEvent> {
    let ioQueue = DispatchQueue(label: "dev.roman.MeetRec.process-tap")

    var exclude: [AudioObjectID] = []
    if let own = processObject(forPID: ProcessInfo.processInfo.processIdentifier) {
        exclude.append(own)
    }
    let description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
    description.name = "MeetRec Tap"
    description.isPrivate = true
    description.muteBehavior = .unmuted

    // Creating the tap triggers the system-audio-recording permission
    // prompt on first use; a denial surfaces as an error status here.
    var tapID = AudioObjectID(kAudioObjectUnknown)
    let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
    guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
        throw CaptureError(
            "Could not create the audio tap (error \(tapStatus)). Allow MeetRec in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
        )
    }

    var formatAddress = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var asbd = AudioStreamBasicDescription()
    var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let formatStatus = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &asbdSize, &asbd)
    guard formatStatus == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
        AudioHardwareDestroyProcessTap(tapID)
        throw CaptureError("Could not read the audio tap's format (error \(formatStatus)).")
    }

    // Aggregate device hosting the tap; the default output device provides
    // the clock so tap timing matches what the user hears.
    var aggregateDescription: [String: Any] = [
        kAudioAggregateDeviceNameKey as String: "MeetRec Tap Device",
        kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey as String: true,
        kAudioAggregateDeviceIsStackedKey as String: false,
        kAudioAggregateDeviceTapAutoStartKey as String: true,
        kAudioAggregateDeviceTapListKey as String: [
            [
                kAudioSubTapUIDKey as String: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey as String: true,
            ],
        ],
    ]
    if let outputUID = defaultOutputDeviceUID() {
        aggregateDescription[kAudioAggregateDeviceMainSubDeviceKey as String] = outputUID
        aggregateDescription[kAudioAggregateDeviceSubDeviceListKey as String] = [
            [kAudioSubDeviceUIDKey as String: outputUID]
        ]
    }
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
    guard aggregateStatus == noErr, aggregateID != kAudioObjectUnknown else {
        AudioHardwareDestroyProcessTap(tapID)
        throw CaptureError("Could not create the capture device (error \(aggregateStatus)).")
    }

    let (stream, continuation) = AsyncStream.makeStream(of: CaptureEvent.self, bufferingPolicy: .unbounded)

    // CoreAudio invokes the block on ioQueue (not the realtime HAL thread),
    // so yielding here is safe.
    var ioProcID: AudioDeviceIOProcID?
    let procStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { inNow, inInputData, inInputTime, _, _ in
        let listPointer = UnsafeMutablePointer(mutating: inInputData)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: listPointer, deallocator: nil),
              buffer.frameLength > 0
        else { return }
        // Prefer the input-data timestamp; fall back to "now" if the HAL
        // didn't mark it valid.
        let stamp = inInputTime.pointee
        let hostTime = (stamp.mFlags.contains(.hostTimeValid) && stamp.mHostTime != 0)
            ? stamp.mHostTime
            : inNow.pointee.mHostTime
        continuation.yield(.bytes(data: rawBytes(of: buffer), pts: microseconds(fromHostTime: hostTime)))
    }
    guard procStatus == noErr, let ioProcID else {
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
        throw CaptureError("Could not attach to the capture device (error \(procStatus)).")
    }

    let startStatus = AudioDeviceStart(aggregateID, ioProcID)
    guard startStatus == noErr else {
        AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
        throw CaptureError("Could not start audio capture (error \(startStatus)).")
    }

    continuation.yield(.opened(format))

    // Fires once the stream stops being iterated.
    continuation.onTermination = { _ in
        ioQueue.async {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    return stream
}

private func processObject(forPID pid: pid_t) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var pidVar = pid
    var objectID = AudioObjectID(kAudioObjectUnknown)
    var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pidVar, &dataSize, &objectID
    )
    guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
    return objectID
}

private func defaultOutputDeviceUID() -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceUID(deviceID)
}

private func deviceUID(_ deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0) }
    guard status == noErr, let value else { return nil }
    return value as String
}
