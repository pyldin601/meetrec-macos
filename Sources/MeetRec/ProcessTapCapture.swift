import AudioToolbox
import AVFoundation
import CoreAudio

/// Captures the whole system output mix (excluding MeetRec's own audio)
/// with a CoreAudio process tap (macOS 14.2+) into an AAC .m4a file.
/// Capture runs from init until `stop()`.
///
/// Needs only the "System Audio Recording Only" permission — never Screen
/// Recording. The permission prompt appears when the first tap is created;
/// a denial surfaces as a creation error.
final class ProcessTapCapture {
    private let ioQueue = DispatchQueue(label: "dev.roman.MeetRec.system-tap")
    private let writer: AudioFileWriter
    private let format: AVAudioFormat
    private let silenceBuffer: AVAudioPCMBuffer?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false

    // Timeline reconstruction. What the tap delivers during system-wide
    // silence is not reliably specified — it may tick with zeroed buffers,
    // or deliver nothing until some process renders audio. The file must be
    // wall-clock continuous regardless (it has to stay aligned with the mic
    // track), so the timeline is anchored to the host clock and undelivered
    // stretches are padded with silence. Gaps are measured between
    // successive deliveries — never against the session start, which would
    // let host-vs-device clock drift accumulate into a false gap.
    // Touched only on ioQueue (stop() drains the queue before its trailing
    // pad).
    private var lastDeliveryHostTime: UInt64 = 0
    private var lastDeliveredFrames: Int64 = 0
    /// Gaps shorter than this are ignored: callback jitter and device
    /// spin-up must never perforate continuous audio with micro-padding.
    private let paddingThresholdSeconds = 0.5

    init(url: URL) throws {
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

        let writer: AudioFileWriter
        do {
            writer = try AudioFileWriter(url: url, format: tapFormat)
        } catch {
            AudioHardwareDestroyProcessTap(tap)
            throw error
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
            writer.finalize()
            AudioHardwareDestroyProcessTap(tap)
            throw MeetRecError("Could not create the capture device (error \(aggregateStatus)).")
        }

        self.writer = writer
        self.format = tapFormat
        self.silenceBuffer = Self.makeSilenceBuffer(format: tapFormat)
        self.tapID = tap
        self.aggregateID = aggregate

        // CoreAudio invokes the block on ioQueue (not the realtime HAL
        // thread), so encoding in the writer here is safe.
        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregate, ioQueue) {
            [weak self] inNow, inInputData, inInputTime, _, _ in
            self?.handleIO(now: inNow, data: inInputData, time: inInputTime)
        }
        guard procStatus == noErr, let procID = newProcID else {
            cleanUp()
            writer.finalize()
            throw MeetRecError("Could not attach to the capture device (error \(procStatus)).")
        }
        ioProcID = procID

        lastDeliveryHostTime = mach_absolute_time()
        let startStatus = AudioDeviceStart(aggregate, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregate, procID)
            ioProcID = nil
            cleanUp()
            writer.finalize()
            throw MeetRecError("Could not start system audio capture (error \(startStatus)).")
        }
        running = true
    }

    /// Stops capture, pads the trailing silence, and finalizes the file; a
    /// file that captured nothing is deleted.
    func stop() {
        if running, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            running = false
        }
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        cleanUp()
        // Drain in-flight IO callbacks, then pad up to the stop instant so
        // the file spans the whole session even if the tap went quiet. The
        // threshold keeps a start-failure rollback (which runs within
        // milliseconds) from padding a file that should be discarded.
        ioQueue.sync {}
        if lastDeliveryHostTime != 0 {
            ioQueue.sync { padDeliveryGap(upTo: mach_absolute_time()) }
            lastDeliveryHostTime = 0
        }
        writer.finalize()
    }

    // MARK: - IO (ioQueue only)

    private func handleIO(
        now: UnsafePointer<AudioTimeStamp>,
        data: UnsafePointer<AudioBufferList>,
        time: UnsafePointer<AudioTimeStamp>
    ) {
        let listPointer = UnsafeMutablePointer(mutating: data)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: listPointer, deallocator: nil),
              buffer.frameLength > 0
        else { return }
        let stamp = time.pointee
        let hostTime = (stamp.mFlags.contains(.hostTimeValid) && stamp.mHostTime != 0)
            ? stamp.mHostTime
            : now.pointee.mHostTime
        padDeliveryGap(upTo: hostTime)
        writer.write(buffer)
        lastDeliveryHostTime = hostTime
        lastDeliveredFrames = Int64(buffer.frameLength)
    }

    /// Writes silence for the stretch since the last delivery that the tap
    /// did not cover, so the file stays wall-clock continuous.
    private func padDeliveryGap(upTo hostTime: UInt64) {
        guard let silenceBuffer, lastDeliveryHostTime != 0 else { return }
        let elapsed = Self.hostDeltaSeconds(from: lastDeliveryHostTime, to: hostTime)
        // The previous delivery's frames cover the start of the interval.
        var gap = Int64(elapsed * format.sampleRate) - lastDeliveredFrames
        guard gap > Int64(paddingThresholdSeconds * format.sampleRate) else { return }
        while gap > 0 {
            let chunk = AVAudioFrameCount(min(gap, Int64(silenceBuffer.frameCapacity)))
            silenceBuffer.frameLength = chunk
            writer.write(silenceBuffer)
            gap -= Int64(chunk)
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

    private static func makeSilenceBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // One second of zeroed frames, reused for every pad chunk.
        let frames = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = audioBuffer.mData {
                memset(data, 0, Int(audioBuffer.mDataByteSize))
            }
        }
        return buffer
    }

    private func cleanUp() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
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
