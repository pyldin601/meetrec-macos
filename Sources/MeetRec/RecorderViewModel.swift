import AppKit
import AVFoundation
import CoreAudio
import CoreGraphics
import Foundation
import Observation
import ScreenCaptureKit

@MainActor
@Observable
final class RecorderViewModel {
    var sourceMode: SourceMode = .application
    var selectedAppPID: pid_t?
    var selectedWindowID: CGWindowID?
    var selectedMicID: AudioDeviceID?
    var lastError: String?

    private(set) var apps: [SCRunningApplication] = []
    private(set) var windows: [SCWindow] = []
    private(set) var mics: [MicDevice] = []
    private(set) var state: RecordingState = .idle
    private(set) var screenAccessGranted = true
    private(set) var micAccessDenied = false
    private(set) var isRefreshingContent = false

    private var display: SCDisplay?
    private var session: RecordingSession?
    private var activity: NSObjectProtocol?
    private var deviceListListenerInstalled = false
    private var didPreselectMic = false
    private var didRequestScreenAccess = false

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var recordingStartDate: Date? {
        if case .recording(let startedAt) = state { return startedAt }
        return nil
    }

    var selectedTarget: CaptureTarget? {
        switch sourceMode {
        case .application:
            return apps.first { $0.processID == selectedAppPID }.map(CaptureTarget.app)
        case .window:
            return windows.first { $0.windowID == selectedWindowID }.map(CaptureTarget.window)
        }
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
        installDeviceListListener()
        Task { await refreshShareableContent() }
    }

    func refreshShareableContent() async {
        guard !isRefreshingContent else { return }
        isRefreshingContent = true
        defer { isRefreshingContent = false }
        do {
            let content = try await ShareableContentProvider.fetch()
            apps = content.apps
            windows = content.windows
            display = content.display
            screenAccessGranted = true
            if let pid = selectedAppPID, !apps.contains(where: { $0.processID == pid }) {
                selectedAppPID = nil
            }
            if let windowID = selectedWindowID, !windows.contains(where: { $0.windowID == windowID }) {
                selectedWindowID = nil
            }
        } catch {
            apps = []
            windows = []
            display = nil
            screenAccessGranted = Permissions.screenCaptureGranted
            if !screenAccessGranted, !didRequestScreenAccess {
                didRequestScreenAccess = true
                Permissions.requestScreenCaptureAccess()
            }
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
        if selectedTarget != nil, !Permissions.screenCaptureGranted {
            Permissions.requestScreenCaptureAccess()
            screenAccessGranted = false
            state = .idle
            lastError = "Screen Recording permission is required to capture app audio. Enable MeetRec in System Settings, then relaunch the app."
            return
        }

        let session = RecordingSession(target: selectedTarget, display: display, mic: selectedMic)
        session.onSourceDied = { [weak self] reason in
            Task { @MainActor in await self?.stopRecording(reason: reason) }
        }
        do {
            try await session.start()
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
        await session.stop()
        self.session = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        state = .idle
        lastError = reason
        // Source lists may have changed while recording (apps quit, windows
        // closed, devices unplugged).
        refreshMics()
        Task { await refreshShareableContent() }
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

    private func installDeviceListListener() {
        guard !deviceListListenerInstalled else { return }
        deviceListListenerInstalled = true
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main
        ) { [weak self] _, _ in
            Task { @MainActor in self?.refreshMics() }
        }
    }
}
