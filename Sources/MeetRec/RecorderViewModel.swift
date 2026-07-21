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

    /// True after mic capture was lost involuntarily with no replacement: the
    /// next input device to appear is attached automatically (SPEC.md §3.2).
    /// Any explicit mic selection — device or None — disarms it.
    private var micResumeArmed = false
    /// Rejects overlapping mic transitions: the mid-session permission
    /// request is the one async step, and device notifications coalesce.
    private var micTransitionInProgress = false
    private var micRetryScheduled = false
    /// Timestamps of automatic mic restarts — flapping-cable guard.
    private var recentMicRestarts: [Date] = []

    private static let micDeniedMessage =
        "Microphone access is denied. Allow MeetRec in System Settings › Privacy & Security › Microphone."

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

    /// While recording with the mic as the only active source, ending mic
    /// capture would end the session — the menu disables None then.
    var isMicSoleActiveSource: Bool {
        guard isRecording, let session else { return false }
        return session.isMicActive && !session.isSystemAudioActive
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
        scheduleAutoResumeIfNeeded()
    }

    func startRecording() async {
        guard canRecord else { return }
        lastError = nil
        micResumeArmed = false
        recentMicRestarts.removeAll()
        state = .preparing

        if selectedMic != nil {
            let granted = await Permissions.requestMicrophoneAccess()
            micAccessDenied = !granted
            guard granted else {
                state = .idle
                lastError = Self.micDeniedMessage
                return
            }
        }

        let session = RecordingSession(target: selectedTarget, mic: selectedMic)
        session.onSourceDied = { [weak self] reason in
            Task { @MainActor in await self?.stopRecording(reason: reason) }
        }
        session.onMicDied = { [weak self] device, reason in
            self?.handleMicDeath(dead: device, reason: reason)
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
        micResumeArmed = false
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

    // MARK: - Mic selection & failover

    /// Single entry point for Microphone submenu clicks (nil = None). While
    /// recording, a device click switches mic capture into a new segment;
    /// None ends mic capture while the session continues (SPEC.md §1.3).
    func selectMic(_ id: AudioDeviceID?) async {
        switch state {
        case .idle:
            micResumeArmed = false
            selectedMicID = id
        case .recording:
            guard let session, !micTransitionInProgress else { return }
            guard let id else {
                micResumeArmed = false
                // The menu disables None while the mic is the sole active
                // source; guard anyway so a stale menu can't end the session.
                if session.isSystemAudioActive {
                    session.detachMic()
                    selectedMicID = nil
                }
                return
            }
            if id == selectedMicID, session.isMicActive { return }
            guard let device = mics.first(where: { $0.id == id }) else { return }
            // The click is accepted from here on, so it now counts as an
            // explicit selection (SPEC.md §3.2 — disarms auto-resume).
            // Dropped clicks above must leave a pending auto-resume armed.
            micResumeArmed = false

            micTransitionInProgress = true
            defer { micTransitionInProgress = false }
            let granted = await Permissions.requestMicrophoneAccess()
            micAccessDenied = !granted
            guard granted else {
                lastError = Self.micDeniedMessage
                return
            }
            // Re-validate across the await: the session may have stopped —
            // or been replaced by a new one this click never targeted — and
            // the device may be gone.
            guard case .recording = state, self.session === session else { return }
            guard MicrophoneDeviceProvider.isAlive(device.id) else {
                // The click attached nothing; restore the auto-resume promise
                // if the session is running without a mic. (.recording with
                // no active mic implies system audio is active — a mic-only
                // session would have stopped instead.)
                if !session.isMicActive {
                    micResumeArmed = true
                    scheduleAutoResumeIfNeeded()
                }
                return
            }
            let previousID = selectedMicID
            do {
                try session.attachMic(device)
                selectedMicID = device.id
            } catch {
                // Silent recovery per SPEC.md §3.3; alert only on total loss.
                if !recoverMic(preferring: previousID, excludingUID: device.uid) {
                    armForResumeOrStop(reason: "Could not start \(device.name): \(error.localizedDescription).")
                }
            }
        default:
            break
        }
    }

    private func handleMicDeath(dead: MicDevice, reason: String) {
        guard case .recording = state else { return }
        refreshMics()
        // The flapping cap never applies when the mic is the only source —
        // skipping recovery there would end the whole recording (SPEC.md
        // §3.2 reserves stopping for "no replacement").
        let systemAudioActive = session?.isSystemAudioActive ?? false
        if micRestartAllowed() || !systemAudioActive, recoverMic(preferring: dead.id) {
            return
        }
        armForResumeOrStop(reason: reason)
    }

    /// Failover chain: the preferred device first (the one that just died —
    /// covers configuration-change restarts where it is still alive), then
    /// the current default input, then any other connected device. Every
    /// candidate must be in the refreshed list and alive — right after an
    /// unplug, CoreAudio can still report the corpse as the default input.
    private func recoverMic(preferring preferredID: AudioDeviceID?, excludingUID: String? = nil) -> Bool {
        guard case .recording = state, let session else { return false }

        var candidates: [MicDevice] = []
        var seenUIDs = Set<String>()
        func add(_ device: MicDevice?) {
            guard let device,
                  device.uid != excludingUID,
                  !seenUIDs.contains(device.uid),
                  MicrophoneDeviceProvider.isAlive(device.id)
            else { return }
            seenUIDs.insert(device.uid)
            candidates.append(device)
        }
        if let preferredID {
            add(mics.first { $0.id == preferredID })
        }
        if let defaultID = MicrophoneDeviceProvider.defaultInputDeviceID() {
            add(mics.first { $0.id == defaultID })
        }
        for device in mics { add(device) }

        for device in candidates {
            do {
                try session.attachMic(device)
            } catch {
                continue
            }
            selectedMicID = device.id
            micResumeArmed = false
            noteMicRestart()
            return true
        }
        return false
    }

    private func armForResumeOrStop(reason: String) {
        guard let session, session.isSystemAudioActive else {
            // Sole source lost: the selection resets to None (SPEC.md §3.2)
            // even when the dead device is still enumerated by CoreAudio.
            selectedMicID = nil
            Task { await stopRecording(reason: reason) }
            return
        }
        selectedMicID = nil
        micResumeArmed = true
        lastError = reason
            + " Recording continues with system audio; the microphone will reconnect automatically when an input device becomes available."
    }

    private func scheduleAutoResumeIfNeeded() {
        guard micResumeArmed, isRecording else { return }
        // Capture work must not run synchronously here: refreshMics is called
        // inline from menuNeedsUpdate while AppKit is building the menu.
        Task { @MainActor [weak self] in self?.autoResumeMicIfNeeded() }
    }

    private func autoResumeMicIfNeeded() {
        guard micResumeArmed, isRecording, !micTransitionInProgress,
              let session, !session.isMicActive, !mics.isEmpty
        else { return }
        guard micRestartAllowed() else {
            // Rate-limited right now; keep the retry chain alive so resume
            // fires once the 30 s window drains (no device event will).
            scheduleMicResumeRetry()
            return
        }
        if !recoverMic(preferring: MicrophoneDeviceProvider.defaultInputDeviceID()) {
            // A freshly plugged device may not publish streams yet.
            scheduleMicResumeRetry()
        }
    }

    private func scheduleMicResumeRetry() {
        guard !micRetryScheduled else { return }
        micRetryScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self else { return }
            self.micRetryScheduled = false
            self.autoResumeMicIfNeeded()
        }
    }

    /// Flapping guard: at most 6 automatic restarts per 30 s; beyond that
    /// the mic goes to lost/armed until the window drains.
    private func micRestartAllowed() -> Bool {
        let now = Date()
        recentMicRestarts.removeAll { now.timeIntervalSince($0) >= 30 }
        return recentMicRestarts.count < 6
    }

    private func noteMicRestart() {
        recentMicRestarts.append(Date())
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
            mSelector: AudioProcessProvider.processObjectListSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(systemObject, &processAddress, .main) { [weak self] _, _ in
            Task { @MainActor in self?.refreshAudioApps() }
        }
    }
}
