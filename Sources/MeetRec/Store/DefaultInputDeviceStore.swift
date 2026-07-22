import CoreAudio
import Foundation

/// The system default audio input device.
///
/// `changes` is multicast: every access returns an independent stream that
/// yields the current device first, then every change. `nil` means there is
/// no usable default input device — none connected, or the read failed.
@MainActor
final class DefaultInputDeviceStore {
    private(set) var deviceID: AudioDeviceID?
    private var subscribers: [UUID: AsyncStream<AudioDeviceID?>.Continuation] = [:]
    private var listener: AudioObjectPropertyListenerBlock?

    init() {
        deviceID = Self.readDeviceID()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        listener = block
        var address = Self.address
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    deinit {
        guard let listener else { return }
        var address = Self.address
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }

    var changes: AsyncStream<AudioDeviceID?> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioDeviceID?.self)
        let id = UUID()
        continuation.yield(deviceID)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[id] = nil }
        }
        return stream
    }

    private func refresh() {
        let current = Self.readDeviceID()
        guard current != deviceID else { return }
        deviceID = current
        for subscriber in subscribers.values {
            subscriber.yield(current)
        }
    }

    private nonisolated static let address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func readDeviceID() -> AudioDeviceID? {
        var address = address
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}
