import CoreAudio

/// The system's current default audio input device, or `nil` if none is
/// usable — no device connected, or the read failed.
func defaultInputDeviceID() -> AudioDeviceID? {
    var address = getDefaultInputDeviceAddress()
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
}

/// Emits the current default input device immediately, then emits whenever
/// the system default input device changes.
func defaultInputDeviceIDs() -> AsyncStream<AudioDeviceID?> {
    AsyncStream { continuation in
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

        var address = getDefaultInputDeviceAddress()

        let queue = DispatchQueue(
            label: "default-input-device-listener"
        )

        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            continuation.yield(defaultInputDeviceID())
        }

        let status = AudioObjectAddPropertyListenerBlock(
            systemObjectID,
            &address,
            queue,
            listener
        )

        guard status == noErr else {
            continuation.finish()
            return
        }

        // Emit the initial value.
        continuation.yield(defaultInputDeviceID())

        continuation.onTermination = { @Sendable _ in
            var removalAddress = getDefaultInputDeviceAddress()

            AudioObjectRemovePropertyListenerBlock(
                systemObjectID,
                &removalAddress,
                queue,
                listener
            )
        }
    }
}

// Private

private func getDefaultInputDeviceAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}
