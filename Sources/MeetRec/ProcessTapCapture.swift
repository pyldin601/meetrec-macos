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

        // CoreAudio invokes the block on ioQueue (not the realtime HAL
        // thread), so encoding in the writer here is safe.
        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, ioQueue) { _, inInputData, _, _, _ in
            let listPointer = UnsafeMutablePointer(mutating: inInputData)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: listPointer, deallocator: nil),
                  buffer.frameLength > 0
            else { return }
            writer.write(buffer)
        }
        guard procStatus == noErr, let procID = newProcID else {
            cleanUp()
            throw MeetRecError("Could not attach to the capture device (error \(procStatus)).")
        }
        ioProcID = procID

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
