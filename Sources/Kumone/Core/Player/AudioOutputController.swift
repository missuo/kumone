#if os(macOS)
import CoreAudio
import Foundation
import SwiftUI

/// The macOS output-route model behind the player's route button.
///
/// Owns the device list, the user's choice and the fallback, and hands the
/// resolved device to whoever is doing the playing (`PlayerService` wires
/// `PlaybackEngine.setOutputDevice` in through `attach`). Kept a singleton so
/// the menu view can reach it without threading an EnvironmentObject through
/// every call site of `RoutePickerButton`.
///
/// See `AudioOutputDevices` for why an AVAudioEngine app on macOS has to do
/// this itself instead of using `AVRoutePickerView`.
@MainActor
final class AudioOutputController: ObservableObject {
    static let shared = AudioOutputController()

    /// Output devices CoreAudio publishes, in menu order.
    @Published private(set) var devices: [AudioOutputDevice] = []
    /// What the menu shows a checkmark against.
    @Published private(set) var selection: AudioOutputSelection = .systemDefault
    /// What "系统默认" currently resolves to. Published separately because a
    /// default-output change leaves `devices` untouched, and the picker's
    /// "系统默认 · …" line and the button's highlight both depend on it.
    @Published private(set) var defaultDeviceID: AudioDeviceID?

    private var state = AudioOutputSelectionState()
    /// Set by `PlayerService`; nil means "no engine yet", and the resolved
    /// device is re-applied when one attaches.
    private var apply: ((AudioDeviceID?) -> Void)?
    private var resolvedDeviceID: AudioDeviceID?
    private var listening = false

    /// When a hardware-driven route change is allowed to reach the engine;
    /// see `OutputRouteChangeDamper` for what it is defending against.
    private var damper = OutputRouteChangeDamper()
    /// The single pending "ask the damper again" timer.
    private var settleTask: Task<Void, Never>?
    /// The breaker opening this controller has already journalled, so a held
    /// route says so once rather than on every suppressed change.
    private var announcedBreakerUntil: Date?

    private init() {}

    /// Where the audio is actually going right now.
    var activeDevice: AudioOutputDevice? {
        AudioOutputDevices.activeDevice(
            selection: selection, devices: devices, defaultID: defaultDeviceID)
    }

    /// Name of the device "系统默认" resolves to, when known.
    var systemDefaultName: String? {
        AudioOutputDevices.systemDefaultName(defaultID: defaultDeviceID, devices: devices)
    }

    /// The name shown on the button's tooltip / VoiceOver value: the chosen
    /// device, or "系统默认 · <device>" when following the default.
    var currentDisplayName: String {
        if case .device(let uid) = selection,
           let device = devices.first(where: { $0.uid == uid }) {
            return device.name
        }
        guard let name = systemDefaultName else { return String(localized: "系统默认") }
        return String(localized: "系统默认 · \(name)")
    }

    /// True when the button should light up; see
    /// `AudioOutputDevices.isRoutedAway`.
    var isRoutedAway: Bool {
        AudioOutputDevices.isRoutedAway(
            selection: selection, devices: devices, defaultID: defaultDeviceID)
    }

    /// Re-read the device list and the default output — called when the
    /// picker opens. The CoreAudio listeners keep both current while it stays
    /// open; this only covers anything that happened before `attach`, or a
    /// listener that CoreAudio was slow to fire. Does not touch the selection
    /// or the engine: reconciling a vanished device stays the listener's job.
    func refresh() {
        refreshDevices()
    }

    /// Connect the playback engine and restore the persisted choice. Safe to
    /// call more than once; only the first call installs the CoreAudio
    /// listeners.
    func attach(_ apply: @escaping (AudioDeviceID?) -> Void) {
        self.apply = apply
        refreshDevices()
        if !listening {
            listening = true
            installListeners()
            let restored = AudioOutputSelection(
                storageValue: SettingsManager.shared.outputDeviceUID)
            handle(state.restore(restored, from: devices), damped: false)
        } else {
            apply(resolvedDeviceID)
            damper.noteApplied(effectiveTarget())
        }
    }

    /// The user picked a menu row.
    func select(_ selection: AudioOutputSelection) {
        refreshDevices()
        handle(state.select(selection, from: devices), damped: false)
    }

    // MARK: - Internals

    private func refreshDevices() {
        let next = AudioOutputDevices.current()
        if next != devices { devices = next }
        let nextDefault = AudioOutputDevices.defaultDeviceID()
        if nextDefault != defaultDeviceID { defaultDeviceID = nextDefault }
    }

    /// Menu state and persistence always follow the outcome immediately; only
    /// the engine-side route change is ever held back, and `damped` says
    /// whether this outcome is eligible for that.
    private func handle(_ outcome: AudioOutputSelectionState.Outcome, damped: Bool) {
        var lost = false
        switch outcome {
        case .followDefault:
            resolvedDeviceID = nil
        case .use(let device):
            resolvedDeviceID = device.id
        case .lost(let name):
            resolvedDeviceID = nil
            lost = true
            ToastCenter.shared.show(
                String(localized: "“\(name)”已断开，已切换到系统默认输出"))
        }
        selection = state.selection
        SettingsManager.shared.outputDeviceUID = selection.storageValue

        // A vanished device is silence until we move, so it jumps the queue
        // however badly the hardware is behaving.
        guard damped, !lost else {
            perform(damper.userSelected(effectiveTarget(), at: Date()))
            return
        }
        perform(damper.hardwareChanged(to: effectiveTarget(), at: Date()))
    }

    /// The concrete device the engine should be on right now. Resolving
    /// `.systemDefault` here rather than leaving it to
    /// `PlaybackEngine.applyOutputDeviceLocked` is what lets the damper hold a
    /// route: a held `nil` would just be re-resolved to the flapping device.
    private func effectiveTarget() -> AudioDeviceID? {
        resolvedDeviceID ?? AudioOutputDevices.defaultDeviceID()
    }

    private func perform(_ decision: OutputRouteChangeDamper.Decision) {
        switch decision {
        case .ignore:
            break
        case .apply(let id):
            settleTask?.cancel()
            settleTask = nil
            announcedBreakerUntil = nil
            apply?(id)
        case .coalesce(let fireAt):
            scheduleSettle(at: fireAt)
        case .suppressed(let retryAt):
            if announcedBreakerUntil != retryAt {
                announcedBreakerUntil = retryAt
                PlaybackJournal.note("output device change suppressed (flapping)")
            }
            scheduleSettle(at: retryAt)
        }
    }

    private func scheduleSettle(at date: Date) {
        settleTask?.cancel()
        let delay = max(0, date.timeIntervalSinceNow)
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.settleFired()
        }
    }

    /// The settle window (or the breaker's backoff) elapsed. Re-read the route
    /// first: the whole point of waiting was to act on where the hardware ended
    /// up, not on where it was when the storm started.
    private func settleFired() {
        settleTask = nil
        let now = Date()
        refreshDevices()
        _ = damper.hardwareChanged(to: effectiveTarget(), at: now)
        perform(damper.settled(at: now))
    }

    /// Device arrivals/departures, plus default-output changes (which matter
    /// while we are following the default — the engine has to be re-pointed,
    /// and AVAudioEngine's own configuration-change notification only fires
    /// once the output unit has actually moved).
    private func installListeners() {
        for selector in [kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
            ) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.hardwareChanged()
                }
            }
        }
    }

    private func hardwareChanged() {
        refreshDevices()
        handle(state.reconcile(with: devices), damped: true)
    }
}
#endif
