import AudioToolbox
import AVFoundation
import CoreAudio

/// Captures the whole system output mix (excluding MeetRec's own audio)
/// with a CoreAudio process tap (macOS 14.2+) and produces it as an async
/// stream of PCM buffers. Capture runs from init until `stop()` or until
/// the consuming task is cancelled.
///
/// The stream is gapless: what a tap delivers during system-wide silence is
/// not reliably specified, so undelivered stretches beyond a threshold are
/// filled with silence buffers, keeping consumed audio wall-clock
/// continuous. Every element is a self-owned deep copy — CoreAudio's IO
/// buffer is only valid inside the callback, so buffers must be copied to
/// outlive it. (AVAudioPCMBuffer is not Sendable; this is safe because
/// ownership transfers at yield — the producer never touches a copy again.)
///
/// The stream is unicast: exactly one consumer may iterate `buffers`.
///
/// Needs only the "System Audio Recording Only" permission — never Screen
/// Recording. The permission prompt appears when the first tap is created;
/// a denial surfaces as a creation error.
final class SystemAudioCapture {
    let format: AVAudioFormat
    let buffers: AsyncStream<AVAudioPCMBuffer>

    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let ioQueue = DispatchQueue(label: "dev.roman.MeetRec.system-tap")
    private let stateLock = NSLock()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false
    private var tornDown = false

    // Delivery tracking for gap padding, touched only on ioQueue (stop()
    // drains the queue before its trailing pad). Gaps are measured between
    // successive deliveries — never against an absolute session anchor,
    // which would let host-vs-device clock drift accumulate over hours into
    // a false gap.
    private var lastDeliveryHostTime: UInt64 = 0
    private var lastDeliveredFrames: Int64 = 0
    /// Gaps shorter than this are ignored: callback jitter and device
    /// spin-up must never perforate continuous audio with micro-padding.
    private let paddingThresholdSeconds = 0.5

    /// A stalled consumer queues at most this many buffers (roughly 40 s of
    /// audio at typical ~512-frame IO cycles) before the oldest are dropped.
    private static let maxQueuedBuffers = 4096

    init() throws {
        // Everything except MeetRec's own audio (alert sounds).
        var exclude: [AudioObjectID] = []
        if let own = Self.processObject(forPID: ProcessInfo.processInfo.processIdentifier) {
            exclude.append(own)
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        description.name = "MeetRec Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            throw MeetRecError(
                "Could not create the system audio tap (error \(tapStatus)). Allow MeetRec in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
            )
        }

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &asbdSize, &asbd)
        guard formatStatus == noErr, let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            AudioHardwareDestroyProcessTap(tap)
            throw MeetRecError("Could not read the system audio tap's format (error \(formatStatus)).")
        }

        // Aggregate device hosting the tap; the default output device
        // provides the clock so tap timing matches what the user hears.
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
        if let outputUID = Self.defaultOutputDeviceUID() {
            aggregateDescription[kAudioAggregateDeviceMainSubDeviceKey as String] = outputUID
            aggregateDescription[kAudioAggregateDeviceSubDeviceListKey as String] = [
                [kAudioSubDeviceUIDKey as String: outputUID]
            ]
        }
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregate
        )
        guard aggregateStatus == noErr, aggregate != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tap)
            throw MeetRecError("Could not create the capture device (error \(aggregateStatus)).")
        }

        let (stream, continuation) = AsyncStream.makeStream(
            of: AVAudioPCMBuffer.self,
            bufferingPolicy: .bufferingNewest(Self.maxQueuedBuffers)
        )
        self.buffers = stream
        self.continuation = continuation
        self.format = tapFormat
        self.tapID = tap
        self.aggregateID = aggregate

        // If the consumer's task is cancelled (or the stream is dropped),
        // release the hardware; tearDownHardware is idempotent, so the
        // finish() inside stop() arriving here too is harmless.
        continuation.onTermination = { [weak self] _ in
            self?.tearDownHardware()
        }

        // CoreAudio invokes the block on ioQueue (not the realtime HAL
        // thread), so copying and yielding here is safe.
        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregate, ioQueue) {
            [weak self] inNow, inInputData, inInputTime, _, _ in
            self?.handleIO(now: inNow, data: inInputData, time: inInputTime)
        }
        guard procStatus == noErr, let procID = newProcID else {
            tearDownHardware()
            throw MeetRecError("Could not attach to the capture device (error \(procStatus)).")
        }
        ioProcID = procID

        lastDeliveryHostTime = mach_absolute_time()
        let startStatus = AudioDeviceStart(aggregate, procID)
        guard startStatus == noErr else {
            tearDownHardware()
            throw MeetRecError("Could not start system audio capture (error \(startStatus)).")
        }
        running = true
    }

    /// Stops capture, pads the trailing silence, and finishes the stream —
    /// the consumer's for-await loop ends after draining what was captured.
    func stop() {
        tearDownHardware()
        // Drain in-flight IO callbacks, then pad up to the stop instant so
        // consumed audio spans the whole capture even if the tap went
        // quiet. The threshold keeps an immediate start-failure rollback
        // from padding audio that never existed.
        ioQueue.sync {}
        ioQueue.sync {
            padDeliveryGap(upTo: mach_absolute_time())
            lastDeliveryHostTime = 0
        }
        continuation.finish()
    }

    private func tearDownHardware() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !tornDown else { return }
        tornDown = true
        if running, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            running = false
        }
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    // MARK: - IO (ioQueue only)

    private func handleIO(
        now: UnsafePointer<AudioTimeStamp>,
        data: UnsafePointer<AudioBufferList>,
        time: UnsafePointer<AudioTimeStamp>
    ) {
        let listPointer = UnsafeMutablePointer(mutating: data)
        guard let delivered = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: listPointer, deallocator: nil),
              delivered.frameLength > 0
        else { return }
        let stamp = time.pointee
        let hostTime = (stamp.mFlags.contains(.hostTimeValid) && stamp.mHostTime != 0)
            ? stamp.mHostTime
            : now.pointee.mHostTime
        padDeliveryGap(upTo: hostTime)
        if let copy = Self.deepCopy(delivered) {
            continuation.yield(copy)
        }
        lastDeliveryHostTime = hostTime
        lastDeliveredFrames = Int64(delivered.frameLength)
    }

    /// Yields silence for the stretch since the last delivery that the tap
    /// did not cover. Each chunk is freshly allocated — a shared silence
    /// buffer must not be yielded, since queued elements would alias it.
    private func padDeliveryGap(upTo hostTime: UInt64) {
        guard lastDeliveryHostTime != 0 else { return }
        let elapsed = Self.hostDeltaSeconds(from: lastDeliveryHostTime, to: hostTime)
        // The previous delivery's frames cover the start of the interval.
        var gap = Int64(elapsed * format.sampleRate) - lastDeliveredFrames
        guard gap > Int64(paddingThresholdSeconds * format.sampleRate) else { return }
        let chunkFrames = Int64(format.sampleRate) // 1 s per chunk
        while gap > 0 {
            let frames = AVAudioFrameCount(min(gap, chunkFrames))
            if let chunk = Self.makeSilenceBuffer(format: format, frames: frames) {
                continuation.yield(chunk)
            }
            gap -= Int64(frames)
        }
    }

    // MARK: - Helpers

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func hostDeltaSeconds(from start: UInt64, to end: UInt64) -> Double {
        guard end > start else { return 0 }
        return Double(end - start) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    private static func deepCopy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (sourceBuffer, destinationBuffer) in zip(source, destination) {
            if let sourceData = sourceBuffer.mData, let destinationData = destinationBuffer.mData {
                memcpy(destinationData, sourceData, Int(min(sourceBuffer.mDataByteSize, destinationBuffer.mDataByteSize)))
            }
        }
        return copy
    }

    private static func makeSilenceBuffer(format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = audioBuffer.mData {
                memset(data, 0, Int(audioBuffer.mDataByteSize))
            }
        }
        return buffer
    }

    private static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidValue) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPointer,
                &size,
                &object
            )
        }
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    private static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        let uidStatus = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, pointer)
        }
        guard uidStatus == noErr, let uid else { return nil }
        return uid as String
    }
}
