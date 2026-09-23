#if os(macOS)
import CoreAudio
import Foundation

/// macOS audio-output routing for an AVAudioEngine app.
///
/// # Why this file exists at all
///
/// Kumone used to hand an `AVRoutePickerView` (`RoutePickerButton`) to the
/// user for AirPlay. That view is a *route picker for an AVFoundation
/// playback object*: on macOS it drives the routing of `AVPlayer` /
/// `AVSampleBufferAudioRenderer`, which pick up the picked route through
/// AVFoundation's own output plumbing. Playback here is an `AVAudioEngine`
/// graph (`PlaybackEngine`) — there is no AVPlayer left in the process — so
/// the picker had nothing to route and selecting an AirPlay speaker did
/// exactly nothing. Verified by inspection: no `AVPlayer` remains under
/// Sources/Kumone/Core/Player.
///
/// What *does* work for an AVAudioEngine on macOS is CoreAudio's device
/// layer: enumerate the output devices (`kAudioHardwarePropertyDevices`) and
/// point the engine's output audio unit at one of them
/// (`AUAudioUnit.setDeviceID`, the typed form of
/// `kAudioOutputUnitProperty_CurrentDevice`). A system-exposed AirPlay
/// receiver shows up in that list as an ordinary device whose transport type
/// is `kAudioDeviceTransportTypeAirPlay` ('airp').
///
/// # What is actually visible on a Mac
///
/// AirPlay endpoints are *not* discovered by this enumeration — CoreAudio
/// only publishes an AirPlay device once macOS itself has materialised it
/// (the user picked the receiver in Sound settings / Control Centre, or the
/// system otherwise exposed it). On the development machine at the time of
/// writing, the output devices were: "OF27UT Pro" (transport `hdmi`),
/// "External Headphones" and "Mac mini Speakers" (both `bltn`) — no `airp`
/// device, because no AirPlay receiver had been selected. So this menu is
/// honest about the platform: it lists what CoreAudio publishes, labels
/// AirPlay endpoints when they are there, and always offers "系统默认",
/// which follows whatever the system route is — including an AirPlay route
/// chosen from Control Centre.
enum AudioOutputDevices {

    // MARK: - Enumeration

    /// Every device with at least one output channel, in menu order.
    static func current() -> [AudioOutputDevice] {
        ordered(rawDevices().compactMap(describe))
    }

    /// The system default output device, or nil if CoreAudio has none.
    static func defaultDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func rawDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0 else { return [] }
        var ids = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    /// Nil for anything the user could not actually pick: input-only devices
    /// (no output channels), hidden devices, devices that refuse to be a
    /// default output (the same rule System Settings › Sound lists by), and
    /// anything whose name or UID CoreAudio will not hand over.
    private static func describe(_ id: AudioDeviceID) -> AudioOutputDevice? {
        guard isOfferable(
            outputChannels: outputChannelCount(id),
            isHidden: uint32Property(id, kAudioDevicePropertyIsHidden).map { $0 != 0 },
            canBeDefault: uint32Property(
                id, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                scope: kAudioDevicePropertyScopeOutput).map { $0 != 0 })
        else { return nil }
        guard let name = stringProperty(id, kAudioObjectPropertyName),
              let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              !name.isEmpty, !uid.isEmpty
        else { return nil }
        return AudioOutputDevice(
            id: id, uid: uid, name: name, transport: transportType(id),
            dataSource: uint32Property(
                id, kAudioDevicePropertyDataSource,
                scope: kAudioDevicePropertyScopeOutput) ?? 0)
    }

    /// Whether a device belongs in the picker at all. A property CoreAudio
    /// does not report (nil) is not held against the device — plenty of
    /// drivers skip the optional ones.
    static func isOfferable(outputChannels: Int, isHidden: Bool?, canBeDefault: Bool?) -> Bool {
        outputChannels > 0 && isHidden != true && canBeDefault != false
    }

    private static func uint32Property(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size)
        else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr
        else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr
        else { return kAudioDeviceTransportTypeUnknown }
        return transport
    }

    // MARK: - Menu order (pure — this is what the tests exercise)

    /// Deduplicated by UID and sorted into the order the menu shows.
    ///
    /// AirPlay endpoints sort last as a group: they come and go, and a device
    /// that appears mid-session must not shove the entry the user is aiming
    /// at somewhere else in the list.
    static func ordered(_ devices: [AudioOutputDevice]) -> [AudioOutputDevice] {
        var seen = Set<String>()
        let unique = devices.filter { seen.insert($0.uid).inserted }
        return unique.sorted { lhs, rhs in
            let (l, r) = (rank(lhs), rank(rhs))
            if l != r { return l < r }
            let byName = lhs.name.localizedStandardCompare(rhs.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.uid < rhs.uid
        }
    }

    /// Built-in, then wired, then Bluetooth, then virtual, then AirPlay —
    /// i.e. the picker's section order, with Bluetooth after wired inside
    /// the external section.
    static func rank(_ device: AudioOutputDevice) -> Int {
        switch device.group {
        case .thisMac: return 0
        case .external: return device.kind == .bluetooth ? 2 : 1
        case .virtual: return 3
        case .airPlay: return 4
        }
    }

    // MARK: - Picker model (pure)

    /// The picker's sections, in display order. Empty sections are dropped,
    /// except AirPlay: it is always present so the picker has somewhere to
    /// explain why no receivers are listed (CoreAudio does no discovery).
    static func sections(_ devices: [AudioOutputDevice]) -> [AudioOutputSection] {
        let sorted = ordered(devices)
        return AudioOutputGroup.allCases.compactMap { group in
            let members = sorted.filter { $0.group == group }
            guard !members.isEmpty || group == .airPlay else { return nil }
            return AudioOutputSection(group: group, devices: members)
        }
    }

    /// Where the audio is actually going: the chosen device while it is
    /// present, otherwise whatever the system default resolves to.
    static func activeDevice(
        selection: AudioOutputSelection, devices: [AudioOutputDevice],
        defaultID: AudioDeviceID?
    ) -> AudioOutputDevice? {
        if case .device(let uid) = selection,
           let chosen = devices.first(where: { $0.uid == uid }) {
            return chosen
        }
        guard let defaultID else { return nil }
        return devices.first { $0.id == defaultID }
    }

    /// Name of the device "系统默认" currently resolves to, if it is one the
    /// picker knows.
    static func systemDefaultName(
        defaultID: AudioDeviceID?, devices: [AudioOutputDevice]
    ) -> String? {
        guard let defaultID else { return nil }
        return devices.first { $0.id == defaultID }?.name
    }

    /// Whether the route button should light up: an explicit choice away
    /// from the default, or the audio landing on an AirPlay receiver (picked
    /// in Control Centre, reached through the default). Bluetooth headphones
    /// reached through the default do not count — that is the normal case.
    static func isRoutedAway(
        selection: AudioOutputSelection, devices: [AudioOutputDevice],
        defaultID: AudioDeviceID?
    ) -> Bool {
        if case .device(let uid) = selection, devices.contains(where: { $0.uid == uid }) {
            return true
        }
        return activeDevice(selection: selection, devices: devices, defaultID: defaultID)?
            .isAirPlay == true
    }
}

/// The picker's sections.
enum AudioOutputGroup: Int, CaseIterable, Sendable {
    /// Built-in speakers and the headphone jack.
    case thisMac
    /// Wired (USB, HDMI, DisplayPort, Thunderbolt, …) and Bluetooth.
    case external
    /// Virtual and aggregate devices (loopback drivers, multi-output).
    case virtual
    /// AirPlay receivers macOS has materialised. Last, because they come and
    /// go and must not shove the row the user is aiming at.
    case airPlay
}

struct AudioOutputSection: Equatable, Sendable {
    let group: AudioOutputGroup
    let devices: [AudioOutputDevice]
}

/// What a device is, as far as the picker's icon and secondary line care.
enum AudioOutputKind: Equatable, Sendable {
    case builtInSpeakers
    case builtInHeadphones
    case bluetooth
    case usb
    case hdmi
    case displayPort
    case thunderbolt
    case airPlay
    case virtual
    case aggregate
    case other

    var group: AudioOutputGroup {
        switch self {
        case .builtInSpeakers, .builtInHeadphones: return .thisMac
        case .airPlay: return .airPlay
        case .virtual, .aggregate: return .virtual
        case .bluetooth, .usb, .hdmi, .displayPort, .thunderbolt, .other: return .external
        }
    }
}

/// One CoreAudio output device, reduced to what the menu and the engine need.
struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    /// Stable across replug and across launches; what gets persisted.
    /// The numeric `id` is *not* stable and must never be stored.
    let uid: String
    let name: String
    /// `kAudioDevicePropertyTransportType` — 'airp' for AirPlay endpoints.
    let transport: UInt32
    /// Output-scope `kAudioDevicePropertyDataSource`, 0 when not reported.
    /// On Apple silicon the built-in device reports 'ispk' for the speakers
    /// and 'hdpn' for the headphone jack ("External Headphones").
    var dataSource: UInt32 = 0

    /// `kIOAudioOutputPortSubTypeHeadphones` ('hdpn'); IOKit's constant, so
    /// spelled out rather than importing IOKit for one four-char code.
    static let headphonesDataSource: UInt32 = 0x6864_706E

    var isAirPlay: Bool { transport == kAudioDeviceTransportTypeAirPlay }

    var kind: AudioOutputKind {
        switch transport {
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeBuiltIn:
            return dataSource == Self.headphonesDataSource ? .builtInHeadphones : .builtInSpeakers
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeHDMI: return .hdmi
        case kAudioDeviceTransportTypeDisplayPort: return .displayPort
        case kAudioDeviceTransportTypeThunderbolt: return .thunderbolt
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            return .aggregate
        default: return .other
        }
    }

    var group: AudioOutputGroup { kind.group }

    /// SF Symbol for the picker row. Transport decides the family; for the
    /// few products whose default names are recognisable (the Mac's own
    /// speakers, AirPods, HomePod, Apple TV) the name refines it the way
    /// Control Centre's Sound module does. A renamed device just gets the
    /// family glyph.
    var symbolName: String {
        let lower = name.lowercased()
        switch kind {
        case .builtInSpeakers:
            if lower.contains("macbook") { return "laptopcomputer" }
            if lower.contains("imac") { return "desktopcomputer" }
            if lower.contains("mac mini") { return "macmini" }
            if lower.contains("mac studio") { return "macstudio" }
            return "speaker.wave.2"
        case .builtInHeadphones:
            return "headphones"
        case .bluetooth:
            if lower.contains("airpods max") { return "airpodsmax" }
            if lower.contains("airpods pro") { return "airpodspro" }
            if lower.contains("airpods") { return "airpods" }
            return "headphones"
        case .airPlay:
            if lower.contains("homepod mini") { return "homepodmini" }
            if lower.contains("homepod") { return "homepod" }
            if lower.contains("apple tv") { return "appletv" }
            return "airplayaudio"
        case .hdmi, .displayPort:
            return "display"
        case .virtual:
            return "waveform"
        case .aggregate:
            return "square.stack.3d.up"
        case .usb, .thunderbolt, .other:
            return "hifispeaker"
        }
    }
}

/// What the user picked. `.systemDefault` is not a device — it means "follow
/// whatever macOS is using", which is also how an AirPlay route chosen in
/// Control Centre reaches us.
enum AudioOutputSelection: Equatable, Sendable {
    case systemDefault
    case device(uid: String)

    /// Round-trips through UserDefaults. The empty string is the default so a
    /// missing key and an explicit "follow the system" read the same.
    var storageValue: String {
        switch self {
        case .systemDefault: return ""
        case .device(let uid): return uid
        }
    }

    init(storageValue: String?) {
        guard let storageValue, !storageValue.isEmpty else {
            self = .systemDefault
            return
        }
        self = .device(uid: storageValue)
    }
}

/// The selection plus the fallback rule, kept apart from CoreAudio and from
/// SwiftUI so it can be tested headlessly.
///
/// The rule that matters: when the device the user chose disappears — the
/// AirPlay speaker walks out of range mid-song — we fall back to the system
/// default and say so. Staying pointed at a dead device is silence, which is
/// the worst of the three possible behaviours.
struct AudioOutputSelectionState: Equatable {
    private(set) var selection: AudioOutputSelection = .systemDefault
    /// Last name seen for the selected device, so the "it vanished" message
    /// can name it after it is already gone from the device list.
    private(set) var rememberedName: String?

    enum Outcome: Equatable {
        /// Follow the system default output.
        case followDefault
        /// Route to this device.
        case use(AudioOutputDevice)
        /// The selection vanished; selection has been reset to
        /// `.systemDefault` and the user should be told, naming this device.
        case lost(name: String)
    }

    init() {}

    /// The user picked something.
    mutating func select(
        _ selection: AudioOutputSelection, from devices: [AudioOutputDevice]
    ) -> Outcome {
        apply(selection, from: devices, announceMissing: false)
    }

    /// Restoring a persisted choice at launch. A device that is simply not
    /// plugged in yet is not news, so this never announces.
    mutating func restore(
        _ selection: AudioOutputSelection, from devices: [AudioOutputDevice]
    ) -> Outcome {
        apply(selection, from: devices, announceMissing: false)
    }

    /// CoreAudio's device list changed. Announces only when a device that was
    /// actively selected has gone away.
    mutating func reconcile(with devices: [AudioOutputDevice]) -> Outcome {
        apply(selection, from: devices, announceMissing: true)
    }

    private mutating func apply(
        _ next: AudioOutputSelection, from devices: [AudioOutputDevice],
        announceMissing: Bool
    ) -> Outcome {
        switch next {
        case .systemDefault:
            selection = .systemDefault
            rememberedName = nil
            return .followDefault
        case .device(let uid):
            if let device = devices.first(where: { $0.uid == uid }) {
                selection = .device(uid: uid)
                rememberedName = device.name
                return .use(device)
            }
            let name = rememberedName ?? uid
            selection = .systemDefault
            rememberedName = nil
            return announceMissing ? .lost(name: name) : .followDefault
        }
    }
}

/// Decides *when* a hardware-driven route change is allowed to reach the
/// engine. Pure, clock-injected, and kept out of `AudioOutputController` so the
/// policy can be tested without CoreAudio or a run loop.
///
/// # Why this exists
///
/// Pointing the engine at a device is not a cheap property write: it stops the
/// engine, sets `kAudioOutputUnitProperty_CurrentDevice`, and rebuilds both
/// deck chains from cached positions (`PlaybackEngine.applyOutputDeviceLocked`
/// → `handleConfigurationChange`). Each one is an audible interruption.
///
/// A misbehaving device makes CoreAudio post that change over and over. From a
/// local journal (2026-08-31 14:30–14:31), while `outputDeviceUID` was empty —
/// system-default mode, no user choice involved:
///
/// ```
/// output device change begin from=78 to=891
/// output device change begin from=891 to=916
/// output device change begin from=916 to=941
/// output device change begin from=941 to=966
/// output device change begin from=966 to=991
/// ```
///
/// Five full graph rebuilds in 75 s. The ever-climbing IDs are the signature:
/// this is one device tearing itself down and re-registering, getting a fresh
/// `AudioDeviceID` each time. Nothing downstream can tell those apart from five
/// genuine route changes — `applyOutputDeviceLocked`'s `deviceID != target`
/// guard sees a different number every time and lets all five through.
///
/// So the damping is here, on two timescales that cover two different failure
/// shapes:
///
/// - **Coalescing** (`settleWindow`): a burst of changes inside one window
///   applies once, at the end, with the last target. Kills the storm where a
///   device flaps faster than a listener could notice the first move.
/// - **Circuit breaker** (`breakerLimit` in `breakerWindow`): sustained
///   flapping — like the journal above, spread far enough apart that every one
///   gets its own settle window — stops being followed at all. We hold the
///   device currently in force and try again after `breakerBackoff`. Being
///   pinned to a working device is strictly better than rebuilding the graph
///   every 15 s forever.
///
/// What is deliberately *not* damped: anything the user did (`userSelected`),
/// and the selected device vanishing. Explicit intent is never flapping, and a
/// dead device is silence — the one outcome worse than a rebuild.
struct OutputRouteChangeDamper: Equatable {

    struct Config: Equatable, Sendable {
        /// Changes arriving within this long of the first one apply once, at
        /// the end, with whatever target arrived last.
        var settleWindow: TimeInterval = 2
        /// More than this many applies inside `breakerWindow` opens the breaker.
        var breakerLimit = 4
        var breakerWindow: TimeInterval = 60
        /// How long the breaker stays open before the route is retried.
        var breakerBackoff: TimeInterval = 30
        init() {}
    }

    enum Decision: Equatable {
        /// Route to the pending target now.
        case apply(AudioDeviceID)
        /// Nothing to do — this target is already the one in force.
        case ignore
        /// Hold; ask again via `settled(at:)` no earlier than `fireAt`.
        case coalesce(fireAt: Date)
        /// The breaker is open: keep the current device and ask again via
        /// `settled(at:)` no earlier than `retryAt`.
        case suppressed(retryAt: Date)
    }

    var config: Config

    /// The device the engine is actually on, as far as this damper knows.
    private(set) var applied: AudioDeviceID?
    /// The target waiting for its settle window (or for the breaker to close).
    private(set) var pending: AudioDeviceID?
    private(set) var deadline: Date?
    /// When each recent apply happened, trimmed to `breakerWindow`.
    private(set) var recentApplies: [Date] = []
    /// Non-nil while the breaker is open; the moment it may be retried.
    private(set) var breakerOpenUntil: Date?

    var isBreakerOpen: Bool { breakerOpenUntil != nil }

    init(config: Config = Config()) {
        self.config = config
    }

    /// A hardware listener reported a route change to `target`.
    mutating func hardwareChanged(to target: AudioDeviceID?, at now: Date) -> Decision {
        // An unresolvable target (CoreAudio has no default device yet) is not
        // something to schedule a rebuild around.
        guard let target else { return .ignore }
        // Already there, and nothing queued behind it: the storm's own no-op.
        if target == applied, pending == nil { return .ignore }

        if let open = breakerOpenUntil {
            // Remember where the flapping device wants us, so the retry after
            // the backoff lands on the *current* truth rather than a stale one.
            pending = target
            return .suppressed(retryAt: open)
        }
        pending = target
        // Fixed window from the *first* change of a burst, not a debounce that
        // extends on every event: a device flapping just inside the window
        // would otherwise defer the route forever. Sustained flapping is the
        // breaker's job, not this one's.
        if let deadline { return .coalesce(fireAt: deadline) }
        let fireAt = now.addingTimeInterval(config.settleWindow)
        deadline = fireAt
        return .coalesce(fireAt: fireAt)
    }

    /// The settle window (or the breaker backoff) elapsed. Returns what should
    /// happen to the target that was waiting.
    mutating func settled(at now: Date) -> Decision {
        if let open = breakerOpenUntil {
            guard now >= open else { return .suppressed(retryAt: open) }
            // Backoff spent: close the breaker with a clean budget, and let the
            // pending target through immediately — we have already waited far
            // longer than any settle window.
            breakerOpenUntil = nil
            recentApplies.removeAll()
            deadline = nil
            return commit(at: now)
        }
        guard let deadline else { return .ignore }
        guard now >= deadline else { return .coalesce(fireAt: deadline) }
        self.deadline = nil

        // Breaker check happens *before* the apply that would trip it, so the
        // limit is the number of rebuilds actually performed in the window.
        recentApplies.removeAll { now.timeIntervalSince($0) > config.breakerWindow }
        if recentApplies.count >= config.breakerLimit {
            let retryAt = now.addingTimeInterval(config.breakerBackoff)
            breakerOpenUntil = retryAt
            return .suppressed(retryAt: retryAt)
        }
        return commit(at: now)
    }

    /// The user picked a route. Never damped, and it resets the breaker
    /// completely: an explicit choice is evidence about intent, not about
    /// hardware weather. It does not spend any of the budget either — the
    /// breaker counts *hardware-driven* rebuilds, and a route the user asked
    /// for out loud is not one of them.
    mutating func userSelected(_ target: AudioDeviceID?, at now: Date) -> Decision {
        pending = nil
        deadline = nil
        breakerOpenUntil = nil
        recentApplies.removeAll()
        applied = target
        guard let target else { return .ignore }
        return .apply(target)
    }

    /// The engine moved for a reason this damper did not decide (a rebuild it
    /// was not asked about, or the very first route at attach time), so the
    /// "already there" test keeps telling the truth.
    mutating func noteApplied(_ target: AudioDeviceID?) {
        applied = target
    }

    private mutating func commit(at now: Date) -> Decision {
        guard let target = pending else { return .ignore }
        pending = nil
        guard target != applied else { return .ignore }
        applied = target
        recentApplies.append(now)
        return .apply(target)
    }
}
#endif
