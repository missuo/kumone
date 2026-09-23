#if os(macOS)
import CoreAudio
import Foundation
import Testing
@testable import KumoneCore

// macOS output routing. The CoreAudio enumeration itself needs real hardware
// (and an AirPlay endpoint that may not exist on any given machine), so what
// is pinned here is everything downstream of it: how a device list becomes a
// menu, how a choice survives a relaunch, and what happens when the device the
// user picked walks out of range mid-song.
@Suite struct AudioOutputDeviceTests {

    // MARK: - Fixtures

    private func device(
        _ name: String, uid: String? = nil, id: AudioDeviceID = 1,
        transport: UInt32 = kAudioDeviceTransportTypeUSB
    ) -> AudioOutputDevice {
        AudioOutputDevice(
            id: id, uid: uid ?? "uid:\(name)", name: name, transport: transport)
    }

    private var builtIn: AudioOutputDevice {
        device("Mac mini Speakers", id: 72, transport: kAudioDeviceTransportTypeBuiltIn)
    }
    private var hdmi: AudioOutputDevice {
        device("OF27UT Pro", id: 90, transport: kAudioDeviceTransportTypeHDMI)
    }
    private var airPlay: AudioOutputDevice {
        device("客厅 HomePod", id: 200, transport: kAudioDeviceTransportTypeAirPlay)
    }

    // MARK: - Menu order

    @Test func airPlayEndpointsSortLastSoTheListDoesNotShiftUnderTheCursor() {
        let ordered = AudioOutputDevices.ordered([airPlay, hdmi, builtIn])
        #expect(ordered.map(\.name) == ["Mac mini Speakers", "OF27UT Pro", "客厅 HomePod"])
    }

    @Test func bluetoothSitsBetweenWiredAndAirPlay() {
        let bt = device("AirPods Pro", id: 5, transport: kAudioDeviceTransportTypeBluetooth)
        let ordered = AudioOutputDevices.ordered([airPlay, bt, hdmi, builtIn])
        #expect(ordered.map(\.name)
            == ["Mac mini Speakers", "OF27UT Pro", "AirPods Pro", "客厅 HomePod"])
    }

    @Test func sameRankSortsByNameAndTheListIsDedupedByUID() {
        let a = device("Zeta", uid: "u1", id: 1)
        let b = device("Alpha", uid: "u2", id: 2)
        // Same UID surfacing twice (a device seen through two enumerations)
        // must not produce two menu rows.
        let duplicate = device("Zeta", uid: "u1", id: 3)
        let ordered = AudioOutputDevices.ordered([a, b, duplicate])
        #expect(ordered.map(\.name) == ["Alpha", "Zeta"])
    }

    @Test func airPlayDevicesAreLabelledAndGetTheAirPlayGlyph() {
        #expect(airPlay.isAirPlay)
        #expect(airPlay.kind == .airPlay && airPlay.group == .airPlay)
        #expect(airPlay.symbolName == "homepod")
        #expect(!builtIn.isAirPlay)
        #expect(builtIn.symbolName == "macmini")
    }

    // MARK: - Picker model

    private var headphoneJack: AudioOutputDevice {
        AudioOutputDevice(
            id: 77, uid: "uid:jack", name: "External Headphones",
            transport: kAudioDeviceTransportTypeBuiltIn,
            dataSource: AudioOutputDevice.headphonesDataSource)
    }

    @Test func theHeadphoneJackIsTheBuiltInDeviceReportingTheHeadphoneDataSource() {
        #expect(headphoneJack.kind == .builtInHeadphones)
        #expect(headphoneJack.symbolName == "headphones")
        #expect(headphoneJack.group == .thisMac)
        // 'ispk', or no data source at all, is the speakers.
        let speakers = AudioOutputDevice(
            id: 71, uid: "s", name: "Speakers",
            transport: kAudioDeviceTransportTypeBuiltIn, dataSource: 0x6973_706B)
        #expect(speakers.kind == .builtInSpeakers)
        #expect(speakers.symbolName == "speaker.wave.2")
    }

    @Test func eachTransportGetsItsOwnFamilyGlyph() {
        let cases: [(UInt32, String, String)] = [
            (kAudioDeviceTransportTypeBuiltIn, "MacBook Pro扬声器", "laptopcomputer"),
            (kAudioDeviceTransportTypeBuiltIn, "iMac Speakers", "desktopcomputer"),
            (kAudioDeviceTransportTypeBuiltIn, "Mac Studio Speakers", "macstudio"),
            (kAudioDeviceTransportTypeBluetooth, "小明的AirPods Pro", "airpodspro"),
            (kAudioDeviceTransportTypeBluetoothLE, "AirPods Max", "airpodsmax"),
            (kAudioDeviceTransportTypeBluetooth, "AirPods", "airpods"),
            (kAudioDeviceTransportTypeBluetooth, "Sony WH-1000XM5", "headphones"),
            (kAudioDeviceTransportTypeAirPlay, "卧室 HomePod mini", "homepodmini"),
            (kAudioDeviceTransportTypeAirPlay, "客厅 HomePod", "homepod"),
            (kAudioDeviceTransportTypeAirPlay, "Living Room Apple TV", "appletv"),
            (kAudioDeviceTransportTypeAirPlay, "Sonos Five", "airplayaudio"),
            (kAudioDeviceTransportTypeHDMI, "LG TV", "display"),
            (kAudioDeviceTransportTypeDisplayPort, "DELL U2723QE", "display"),
            (kAudioDeviceTransportTypeUSB, "Scarlett 2i2", "hifispeaker"),
            (kAudioDeviceTransportTypeThunderbolt, "Apollo Twin", "hifispeaker"),
            (kAudioDeviceTransportTypeVirtual, "BlackHole 2ch", "waveform"),
            (kAudioDeviceTransportTypeAggregate, "多输出设备", "square.stack.3d.up"),
            (kAudioDeviceTransportTypeUnknown, "Mystery", "hifispeaker"),
        ]
        for (transport, name, symbol) in cases {
            #expect(device(name, transport: transport).symbolName == symbol, "\(name)")
        }
    }

    @Test func sectionsFollowTheSoundModuleOrderAndDropEmptyOnesExceptAirPlay() {
        let bt = device("AirPods Pro", id: 5, transport: kAudioDeviceTransportTypeBluetooth)
        let virtual = device("BlackHole 2ch", id: 6, transport: kAudioDeviceTransportTypeVirtual)
        let sections = AudioOutputDevices.sections([airPlay, virtual, bt, hdmi, headphoneJack, builtIn])
        #expect(sections.map(\.group) == [.thisMac, .external, .virtual, .airPlay])
        #expect(sections[0].devices.map(\.name) == ["External Headphones", "Mac mini Speakers"])
        // Wired before Bluetooth inside the external section.
        #expect(sections[1].devices.map(\.name) == ["OF27UT Pro", "AirPods Pro"])
        #expect(sections[3].devices == [airPlay])
    }

    @Test func theAirPlaySectionIsKeptEvenEmptySoThePickerCanExplainWhy() {
        let sections = AudioOutputDevices.sections([builtIn, hdmi])
        #expect(sections.map(\.group) == [.thisMac, .external, .airPlay])
        #expect(sections.last?.devices.isEmpty == true)
    }

    @Test func virtualDevicesSortBeforeAirPlaySoReceiversStillComeLast() {
        let virtual = device("BlackHole 2ch", id: 6, transport: kAudioDeviceTransportTypeVirtual)
        #expect(AudioOutputDevices.ordered([airPlay, virtual, builtIn]).map(\.name)
            == ["Mac mini Speakers", "BlackHole 2ch", "客厅 HomePod"])
    }

    @Test func onlyDevicesThatCanActuallyBeSelectedAreOffered() {
        #expect(AudioOutputDevices.isOfferable(outputChannels: 2, isHidden: false, canBeDefault: true))
        // Properties a driver does not report are not held against it.
        #expect(AudioOutputDevices.isOfferable(outputChannels: 2, isHidden: nil, canBeDefault: nil))
        #expect(!AudioOutputDevices.isOfferable(outputChannels: 0, isHidden: false, canBeDefault: true))
        #expect(!AudioOutputDevices.isOfferable(outputChannels: 2, isHidden: true, canBeDefault: true))
        #expect(!AudioOutputDevices.isOfferable(outputChannels: 2, isHidden: false, canBeDefault: false))
    }

    @Test func systemDefaultNamesTheDeviceItResolvesTo() {
        let devices = [builtIn, hdmi]
        #expect(AudioOutputDevices.systemDefaultName(defaultID: hdmi.id, devices: devices)
            == "OF27UT Pro")
        #expect(AudioOutputDevices.systemDefaultName(defaultID: nil, devices: devices) == nil)
        // A default the list does not know (yet) says nothing rather than guessing.
        #expect(AudioOutputDevices.systemDefaultName(defaultID: 999, devices: devices) == nil)
    }

    @Test func theActiveDeviceIsTheChoiceWhilePresentElseTheDefault() {
        let devices = [builtIn, hdmi, airPlay]
        #expect(AudioOutputDevices.activeDevice(
            selection: .device(uid: airPlay.uid), devices: devices, defaultID: builtIn.id)
            == airPlay)
        #expect(AudioOutputDevices.activeDevice(
            selection: .systemDefault, devices: devices, defaultID: hdmi.id) == hdmi)
        #expect(AudioOutputDevices.activeDevice(
            selection: .device(uid: "gone"), devices: devices, defaultID: builtIn.id)
            == builtIn)
    }

    @Test func theButtonLightsForAnExplicitChoiceOrAnAirPlayDefaultOnly() {
        let devices = [builtIn, hdmi, airPlay]
        #expect(AudioOutputDevices.isRoutedAway(
            selection: .device(uid: hdmi.uid), devices: devices, defaultID: builtIn.id))
        // AirPlay picked in Control Centre reaches us through the default.
        #expect(AudioOutputDevices.isRoutedAway(
            selection: .systemDefault, devices: devices, defaultID: airPlay.id))
        #expect(!AudioOutputDevices.isRoutedAway(
            selection: .systemDefault, devices: devices, defaultID: builtIn.id))
        let bt = device("AirPods Pro", id: 5, transport: kAudioDeviceTransportTypeBluetooth)
        #expect(!AudioOutputDevices.isRoutedAway(
            selection: .systemDefault, devices: devices + [bt], defaultID: bt.id))
        // A pinned device that has gone is not a route.
        #expect(!AudioOutputDevices.isRoutedAway(
            selection: .device(uid: "gone"), devices: devices, defaultID: builtIn.id))
    }

    // MARK: - Persistence round-trip

    @Test func selectionRoundTripsThroughItsStoredString() {
        let chosen = AudioOutputSelection.device(uid: "AirPlay:0xdeadbeef")
        #expect(AudioOutputSelection(storageValue: chosen.storageValue) == chosen)

        let followSystem = AudioOutputSelection.systemDefault
        #expect(followSystem.storageValue == "")
        #expect(AudioOutputSelection(storageValue: followSystem.storageValue) == followSystem)
    }

    @Test func aMissingOrEmptyStoredValueMeansFollowTheSystem() {
        #expect(AudioOutputSelection(storageValue: nil) == .systemDefault)
        #expect(AudioOutputSelection(storageValue: "") == .systemDefault)
    }

    // MARK: - Fallback state machine

    @Test func pickingAPresentDeviceRoutesToIt() {
        var state = AudioOutputSelectionState()
        let outcome = state.select(.device(uid: airPlay.uid), from: [builtIn, airPlay])
        #expect(outcome == .use(airPlay))
        #expect(state.selection == .device(uid: airPlay.uid))
    }

    @Test func theDeviceWalkingAwayMidSongFallsBackToDefaultAndNamesIt() {
        var state = AudioOutputSelectionState()
        _ = state.select(.device(uid: airPlay.uid), from: [builtIn, airPlay])

        // The HomePod goes out of range: CoreAudio drops it from the list.
        let outcome = state.reconcile(with: [builtIn])
        #expect(outcome == .lost(name: "客厅 HomePod"))
        #expect(state.selection == .systemDefault)
    }

    @Test func theLossIsAnnouncedOnceAndNotOnEveryLaterDeviceChange() {
        var state = AudioOutputSelectionState()
        _ = state.select(.device(uid: airPlay.uid), from: [builtIn, airPlay])
        _ = state.reconcile(with: [builtIn])

        // Plugging headphones in afterwards is not another loss.
        #expect(state.reconcile(with: [builtIn, hdmi]) == .followDefault)
    }

    @Test func unrelatedDeviceChangesLeaveALivingSelectionAlone() {
        var state = AudioOutputSelectionState()
        _ = state.select(.device(uid: airPlay.uid), from: [builtIn, airPlay])
        #expect(state.reconcile(with: [builtIn, hdmi, airPlay]) == .use(airPlay))
        #expect(state.selection == .device(uid: airPlay.uid))
    }

    @Test func restoringAChoiceWhoseDeviceIsNotHereYetIsSilent() {
        // Launching with the HomePod off is not an event worth a toast; it is
        // just the default route.
        var state = AudioOutputSelectionState()
        let outcome = state.restore(.device(uid: airPlay.uid), from: [builtIn])
        #expect(outcome == .followDefault)
        #expect(state.selection == .systemDefault)
    }

    @Test func restoringAChoiceWhoseDeviceIsPresentRoutesStraightToIt() {
        var state = AudioOutputSelectionState()
        #expect(state.restore(.device(uid: airPlay.uid), from: [builtIn, airPlay])
            == .use(airPlay))
    }

    @Test func choosingSystemDefaultForgetsTheRememberedDevice() {
        var state = AudioOutputSelectionState()
        _ = state.select(.device(uid: airPlay.uid), from: [builtIn, airPlay])
        #expect(state.select(.systemDefault, from: [builtIn, airPlay]) == .followDefault)
        // Nothing left to lose, so the endpoint disappearing is silent.
        #expect(state.reconcile(with: [builtIn]) == .followDefault)
    }
}

// Route-change damping. Every rebuild this suppresses is an audible
// interruption the listener would otherwise have got for free, so the policy is
// pinned here rather than left to a comment.
@Suite struct OutputRouteChangeDamperTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func settled(_ config: OutputRouteChangeDamper.Config = .init())
        -> OutputRouteChangeDamper {
        var damper = OutputRouteChangeDamper(config: config)
        damper.noteApplied(78)
        return damper
    }

    // MARK: - Coalescing

    @Test func aSingleChangeWaitsOutTheSettleWindowAndThenApplies() {
        var damper = settled()
        #expect(damper.hardwareChanged(to: 891, at: at(0)) == .coalesce(fireAt: at(2)))
        // Asking early does not let it through.
        #expect(damper.settled(at: at(1)) == .coalesce(fireAt: at(2)))
        #expect(damper.settled(at: at(2)) == .apply(891))
    }

    @Test func aBurstInsideOneWindowCostsOneRebuildAtTheLastTarget() {
        var damper = settled()
        _ = damper.hardwareChanged(to: 891, at: at(0))
        // Three more arrive while the first is still settling.
        #expect(damper.hardwareChanged(to: 916, at: at(0.4)) == .coalesce(fireAt: at(2)))
        #expect(damper.hardwareChanged(to: 941, at: at(1.1)) == .coalesce(fireAt: at(2)))
        #expect(damper.hardwareChanged(to: 966, at: at(1.9)) == .coalesce(fireAt: at(2)))
        // One rebuild, and it lands on where the hardware actually ended up.
        #expect(damper.settled(at: at(2)) == .apply(966))
        #expect(damper.settled(at: at(2)) == .ignore)
    }

    @Test func theWindowIsFixedFromTheFirstChangeSoFlappingCannotDeferForever() {
        var damper = settled()
        _ = damper.hardwareChanged(to: 891, at: at(0))
        // A debounce that extended on every event would never fire here.
        for (i, id) in [916, 941, 966, 991].enumerated() {
            #expect(damper.hardwareChanged(to: AudioDeviceID(id),
                                           at: at(0.5 + Double(i) * 0.5))
                == .coalesce(fireAt: at(2)))
        }
        #expect(damper.settled(at: at(2)) == .apply(991))
    }

    @Test func aChangeBackToTheDeviceAlreadyInForceIsNotARebuild() {
        var damper = settled()
        #expect(damper.hardwareChanged(to: 78, at: at(0)) == .ignore)
        // And a burst that ends where it started costs nothing either.
        _ = damper.hardwareChanged(to: 891, at: at(1))
        _ = damper.hardwareChanged(to: 78, at: at(1.5))
        #expect(damper.settled(at: at(3)) == .ignore)
    }

    @Test func anUnresolvableTargetIsNotSomethingToRebuildAround() {
        var damper = settled()
        #expect(damper.hardwareChanged(to: nil, at: at(0)) == .ignore)
    }

    // MARK: - Circuit breaker

    /// The shape from the journal: a device re-registering with a fresh ID
    /// every ~15 s, far enough apart that coalescing never sees a burst.
    @Test func sustainedFlappingTripsTheBreakerAndHoldsTheCurrentDevice() {
        var damper = settled()
        var applied: [AudioDeviceID] = []
        var time = 0.0
        for id in [891, 916, 941, 966] {
            _ = damper.hardwareChanged(to: AudioDeviceID(id), at: at(time))
            if case .apply(let d) = damper.settled(at: at(time + 2)) { applied.append(d) }
            time += 15
        }
        // Four rebuilds inside the 60 s window is the budget.
        #expect(applied == [891, 916, 941, 966])
        #expect(!damper.isBreakerOpen)

        // The fifth is where we stop following it.
        _ = damper.hardwareChanged(to: 991, at: at(time))
        #expect(damper.settled(at: at(time + 2)) == .suppressed(retryAt: at(time + 32)))
        #expect(damper.isBreakerOpen)
        // And it stays held while the storm continues.
        #expect(damper.hardwareChanged(to: 1016, at: at(time + 5))
            == .suppressed(retryAt: at(time + 32)))
        #expect(damper.settled(at: at(time + 10)) == .suppressed(retryAt: at(time + 32)))
    }

    @Test func theBreakerRetriesTheLatestTargetAfterItsBackoff() {
        var config = OutputRouteChangeDamper.Config()
        config.breakerLimit = 1
        var damper = settled(config)
        _ = damper.hardwareChanged(to: 891, at: at(0))
        #expect(damper.settled(at: at(2)) == .apply(891))
        _ = damper.hardwareChanged(to: 916, at: at(10))
        #expect(damper.settled(at: at(12)) == .suppressed(retryAt: at(42)))

        // While held, the device keeps moving; the retry must land on the
        // newest target, not the one that happened to trip the breaker.
        _ = damper.hardwareChanged(to: 941, at: at(20))
        #expect(damper.settled(at: at(42)) == .apply(941))
        #expect(!damper.isBreakerOpen)
    }

    @Test func rebuildsSpreadWiderThanTheBreakerWindowNeverTripIt() {
        var damper = settled()
        var time = 0.0
        for id in [891, 916, 941, 966, 991, 1016] {
            _ = damper.hardwareChanged(to: AudioDeviceID(id), at: at(time))
            #expect(damper.settled(at: at(time + 2)) == .apply(AudioDeviceID(id)))
            time += 30   // two per minute is a user unplugging things, not a storm
        }
        #expect(!damper.isBreakerOpen)
    }

    // MARK: - What is never damped

    @Test func theUserPickingARouteIsImmediateAndClearsAHeldBreaker() {
        var config = OutputRouteChangeDamper.Config()
        config.breakerLimit = 1
        var damper = settled(config)
        _ = damper.hardwareChanged(to: 891, at: at(0))
        _ = damper.settled(at: at(2))
        _ = damper.hardwareChanged(to: 916, at: at(10))
        #expect(damper.settled(at: at(12)) == .suppressed(retryAt: at(42)))

        // Explicit intent is not hardware weather.
        #expect(damper.userSelected(200, at: at(15)) == .apply(200))
        #expect(!damper.isBreakerOpen)
        // And the storm's next move is followed normally again.
        _ = damper.hardwareChanged(to: 991, at: at(20))
        #expect(damper.settled(at: at(22)) == .apply(991))
    }

    @Test func aUserChoiceDropsAChangeStillWaitingOutItsWindow() {
        var damper = settled()
        _ = damper.hardwareChanged(to: 891, at: at(0))
        #expect(damper.userSelected(200, at: at(1)) == .apply(200))
        // The superseded hardware change must not arrive a second later.
        #expect(damper.settled(at: at(2)) == .ignore)
    }
}
#endif
