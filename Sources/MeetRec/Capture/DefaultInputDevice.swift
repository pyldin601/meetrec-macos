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

        // Some drivers fire the change notification even when the resolved
        // default device hasn't actually changed; track the last emitted ID
        // so those spurious notifications don't retrigger consumers.
        var hasEmitted = false
        var lastDeviceID: AudioDeviceID?

        func emitIfChanged() {
            let currentID = defaultInputDeviceID()
            guard !hasEmitted || currentID != lastDeviceID else { return }
            hasEmitted = true
            lastDeviceID = currentID
            continuation.yield(currentID)
        }

        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            emitIfChanged()
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

        // Emit the initial value. Dispatched onto `queue` (instead of called
        // inline) so it's serialized with the listener callback, which
        // CoreAudio also invokes on `queue` — otherwise the dedup state above
        // could race between this call and a concurrent listener callback.
        queue.async { emitIfChanged() }

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
