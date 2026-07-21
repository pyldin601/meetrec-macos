import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Captures a specific input device with AVAudioEngine and streams the raw
/// (unprocessed) buffers into an AudioFileWriter.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let deviceID: AudioDeviceID
    private var configChangeObserver: NSObjectProtocol?
    private var aliveListener: AudioObjectPropertyListenerBlock?
    private var aliveAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(deviceID: AudioDeviceID) {
        self.deviceID = deviceID
    }

    /// Binds the engine's input to the selected device and returns that
    /// device's hardware format. Must be called before `start`.
    func bind() throws -> AVAudioFormat {
        let input = engine.inputNode
        guard let audioUnit = input.audioUnit else {
            throw MeetRecError("The microphone engine did not provide an input audio unit.")
        }
        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw MeetRecError("Could not select the microphone (CoreAudio error \(status)).")
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MeetRecError("The selected microphone has no usable input format.")
        }
        return format
    }

    func start(writer: AudioFileWriter, onFailure: @escaping (String) -> Void) throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        // Writing the file directly in the tap is safe: taps are delivered on
        // a non-realtime internal thread, not the audio render thread.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            writer.write(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MeetRecError("Could not start the microphone: \(error.localizedDescription)")
        }

        // The engine posts a configuration change when its pinned input device
        // disappears or changes shape mid-recording. It also posts a spurious
        // one right after start (notably when pinned to a non-default device),
        // so only treat it as a source death when the device is actually gone
        // or the engine stopped rendering.
        let deviceID = deviceID
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak engine] _ in
            let engineRunning = engine?.isRunning ?? false
            if !engineRunning || !MicrophoneDeviceProvider.isAlive(deviceID) {
                onFailure("The microphone was disconnected or its configuration changed.")
            }
        }

        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            if !MicrophoneDeviceProvider.isAlive(deviceID) {
                onFailure("The microphone was disconnected.")
            }
        }
        aliveListener = listener
        AudioObjectAddPropertyListenerBlock(deviceID, &aliveAddress, .main, listener)
    }

    func stop() {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        if let aliveListener {
            AudioObjectRemovePropertyListenerBlock(deviceID, &aliveAddress, .main, aliveListener)
            self.aliveListener = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
