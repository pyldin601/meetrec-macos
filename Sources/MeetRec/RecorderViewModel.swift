import AppKit
import AVFoundation
import CoreAudio
import Foundation
import Observation

@MainActor
@Observable
final class RecorderViewModel {
    var selectedTarget: CaptureTarget?
    var selectedMicID: AudioDeviceID?
    var lastError: String?

    private(set) var audioApps: [AudioApp] = []
    private(set) var mics: [MicDevice] = []
    private(set) var state: RecordingState = .idle
    private(set) var micAccessDenied = false

    private var session: RecordingSession?
    private var activity: NSObjectProtocol?
    private var listenersInstalled = false
    private var didPreselectMic = false

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var recordingStartDate: Date? {
        if case .recording(let startedAt) = state { return startedAt }
        return nil
    }

    var selectedMic: MicDevice? {
        mics.first { $0.id == selectedMicID }
    }

    var canRecord: Bool {
        state == .idle && (selectedTarget != nil || selectedMic != nil)
    }

    func bootstrap() {
        micAccessDenied = Permissions.microphoneDenied
        refreshMics()
        refreshAudioApps()
        installListeners()
    }

    func refreshAudioApps() {
        audioApps = AudioProcessProvider.audioApps()
        if state == .idle, case .some(.app(let app)) = selectedTarget, !audioApps.contains(app) {
            selectedTarget = nil
        }
    }

    func refreshMics() {
        mics = MicrophoneDeviceProvider.inputDevices()
        if !didPreselectMic {
            didPreselectMic = true
            if let defaultID = MicrophoneDeviceProvider.defaultInputDeviceID(),
               mics.contains(where: { $0.id == defaultID }) {
                selectedMicID = defaultID
            }
        }
        if state == .idle, let id = selectedMicID, !mics.contains(where: { $0.id == id }) {
            selectedMicID = nil
        }
    }

    func startRecording() async {
        guard canRecord else { return }
        lastError = nil
        state = .preparing

        if selectedMic != nil {
            let granted = await Permissions.requestMicrophoneAccess()
            micAccessDenied = !granted
            guard granted else {
                state = .idle
                lastError = "Microphone access is denied. Allow MeetRec in System Settings › Privacy & Security › Microphone."
                return
            }
        }

        let session = RecordingSession(target: selectedTarget, mic: selectedMic)
        session.onSourceDied = { [weak self] reason in
            Task { @MainActor in await self?.stopRecording(reason: reason) }
        }
        do {
            try session.start()
        } catch {
            state = .idle
            lastError = error.localizedDescription
            return
        }
        self.session = session
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Recording meeting audio"
        )
        state = .recording(startedAt: Date())
    }

    func stopRecording(reason: String? = nil) async {
        guard case .recording = state, let session else { return }
        state = .stopping
        session.stop()
        self.session = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        state = .idle
        lastError = reason
        // Source lists may have changed while recording (apps quit, devices
        // unplugged).
        refreshMics()
        refreshAudioApps()
    }

    /// Called from the app-quit path; safe to call in any state. Returns once
    /// every capture is stopped and all files are finalized.
    func shutDown() async {
        while state == .preparing || state == .stopping {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if case .recording = state {
            await stopRecording()
        }
    }

    private func installListeners() {
        guard !listenersInstalled else { return }
        listenersInstalled = true
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(systemObject, &deviceAddress, .main) { [weak self] _, _ in
            Task { @MainActor in self?.refreshMics() }
        }

        var processAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjects,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(systemObject, &processAddress, .main) { [weak self] _, _ in
            Task { @MainActor in self?.refreshAudioApps() }
        }
    }
}
