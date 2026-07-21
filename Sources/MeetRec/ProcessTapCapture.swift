import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Captures the audio of one application (or the whole system mix) with a
/// CoreAudio process tap (macOS 14.2+) and streams it into an AudioFileWriter.
///
/// Unlike ScreenCaptureKit, this needs only the "System Audio Recording Only"
/// permission — never Screen Recording — and the grant takes effect without
/// relaunching the app.
final class ProcessTapCapture {
    private let ioQueue = DispatchQueue(label: "dev.roman.MeetRec.process-tap")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false

    // Timeline reconstruction. What the tap delivers during system-wide
    // silence is not reliably specified — depending on OS/device state it
    // ticks with zeroed buffers, delivers empty buffers, or delivers nothing
    // until some process renders audio. The file must be wall-clock
    // continuous regardless (SPEC.md §3.1), so the timeline is anchored to
    // the host clock and any undelivered stretch is padded with silence.
    private var writer: AudioFileWriter?
    private var format: AVAudioFormat?
    private var silenceBuffer: AVAudioPCMBuffer?
    // Delivery tracking, touched only on ioQueue (stop() drains the queue
    // before its trailing pad). Gaps are measured between successive
    // deliveries — never against an absolute session anchor, which would let
    // host-vs-device clock drift accumulate over hours into a false gap.
    private var lastDeliveryHostTime: UInt64 = 0
    private var lastDeliveredFrames: Int64 = 0
    /// Gaps shorter than this are ignored: callback jitter and device
    /// spin-up must never perforate continuous audio with micro-padding.
    private let paddingThresholdSeconds = 0.5

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func hostDeltaSeconds(from start: UInt64, to end: UInt64) -> Double {
        guard end > start else { return 0 }
        return Double(end - start) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    func start(target: CaptureTarget, writer: AudioFileWriter) throws {
        let description: CATapDescription
        switch target {
        case .systemAudio:
            // Everything except MeetRec's own audio.
            var exclude: [AudioObjectID] = []
            let ownPID = ProcessInfo.processInfo.processIdentifier
            if let own = AudioProcessProvider.translatePIDToProcessObject(ownPID) {
                exclude.append(own)
            }
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        case .app(let app):
            guard let object = AudioProcessProvider.translatePIDToProcessObject(app.pid) else {
                throw MeetRecError("\(app.name) is not registered with CoreAudio — it may have quit. Refresh the list and try again.")
            }
            description = CATapDescription(stereoMixdownOfProcesses: [object])
        }
        description.name = "MeetRec Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        // Creating the tap triggers the system-audio-recording permission
        // prompt on first use; a denial surfaces as an error status here.
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw MeetRecError("Could not create the audio tap (error \(tapStatus)). Allow MeetRec in System Settings › Privacy & Security › Screen & System Audio Recording, then try again.")
        }
        tapID = newTapID

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &asbdSize, &asbd)
        guard formatStatus == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            cleanUp()
            throw MeetRecError("Could not read the audio tap's format (error \(formatStatus)).")
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
        if let outputUID = Self.defaultOutputDeviceUID() {
            aggregateDescription[kAudioAggregateDeviceMainSubDeviceKey as String] = outputUID
            aggregateDescription[kAudioAggregateDeviceSubDeviceListKey as String] = [
                [kAudioSubDeviceUIDKey as String: outputUID]
            ]
        }
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &newAggregateID
        )
        guard aggregateStatus == noErr, newAggregateID != kAudioObjectUnknown else {
            cleanUp()
            throw MeetRecError("Could not create the capture device (error \(aggregateStatus)).")
        }
        aggregateID = newAggregateID

        self.writer = writer
        self.format = format
        self.silenceBuffer = Self.makeSilenceBuffer(format: format)
        self.lastDeliveredFrames = 0

        // CoreAudio invokes the block on ioQueue (not the realtime HAL
        // thread), so encoding in the writer here is safe.
        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, ioQueue) { [weak self] inNow, inInputData, inInputTime, _, _ in
            guard let self else { return }
            let listPointer = UnsafeMutablePointer(mutating: inInputData)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: listPointer, deallocator: nil),
                  buffer.frameLength > 0
            else { return }
            let stamp = inInputTime.pointee
            let hostTime = (stamp.mFlags.contains(.hostTimeValid) && stamp.mHostTime != 0)
                ? stamp.mHostTime
                : inNow.pointee.mHostTime
            self.padDeliveryGap(upTo: hostTime)
            writer.write(buffer)
            self.lastDeliveryHostTime = hostTime
            self.lastDeliveredFrames = Int64(buffer.frameLength)
        }
        guard procStatus == noErr, let procID = newProcID else {
            cleanUp()
            throw MeetRecError("Could not attach to the capture device (error \(procStatus)).")
        }
        ioProcID = procID

        lastDeliveryHostTime = mach_absolute_time()
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            cleanUp()
            throw MeetRecError("Could not start audio capture (error \(startStatus)).")
        }
        running = true
    }

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
        // Drain in-flight IO callbacks so the writer can be finalized from
        // another context without racing a write.
        ioQueue.sync { }
        // The tap may have delivered nothing (silent system) or stopped
        // early; pad the file up to the stop instant so it spans the whole
        // session. The threshold keeps a start-failure rollback (which runs
        // within milliseconds) from padding a file that should be discarded.
        if lastDeliveryHostTime != 0 {
            ioQueue.sync { padDeliveryGap(upTo: mach_absolute_time()) }
            lastDeliveryHostTime = 0
        }
        writer = nil
        format = nil
        silenceBuffer = nil
    }

    /// ioQueue only. Writes silence for the stretch since the last delivery
    /// that the tap did not cover, so the file stays wall-clock continuous.
    private func padDeliveryGap(upTo hostTime: UInt64) {
        guard let writer, let format, let silenceBuffer, lastDeliveryHostTime != 0 else { return }
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
        return MicrophoneDeviceProvider.deviceUID(deviceID)
    }
}
