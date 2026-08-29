import AVFoundation
import Foundation

enum RepeatMode: String, CaseIterable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// Where the current queue came from — used for scrobbling and UI affordances.
enum PlaySource: Equatable {
    case playlist(Int)
    case album(Int)
    case artist(Int)
    case daily
    case cloud
    case none

    var sourceID: Int {
        switch self {
        case .playlist(let id), .album(let id), .artist(let id): return id
        default: return 0
        }
    }
}

/// Where playback started from — listed under "Recently Played" in the Dock
/// menu, where picking one reloads it and starts playing again.
///
/// This is deliberately separate from `PlaySource`: heartbeat mode plays out
/// of the liked-songs playlist for scrobbling purposes, but as a *place* it is
/// its own thing, and the recents page has no source at all.
struct PlayContext: Codable, Hashable {
    enum Kind: String, Codable {
        /// Reloaded by id.
        case playlist, album, artist
        /// Fixed per-account entry points, each reloaded from its own API.
        case daily, cloud, recents, heartbeat, fm
    }

    let kind: Kind
    /// Zero for the fixed entry points, which have no id of their own.
    let id: Int
    let name: String

    static func playlist(id: Int, name: String) -> PlayContext {
        .init(kind: .playlist, id: id, name: name)
    }

    static func album(id: Int, name: String) -> PlayContext {
        .init(kind: .album, id: id, name: name)
    }

    static func artist(id: Int, name: String) -> PlayContext {
        .init(kind: .artist, id: id, name: name)
    }

    static var daily: PlayContext { .init(kind: .daily, id: 0, name: String(localized: "每日推荐")) }
    static var cloud: PlayContext { .init(kind: .cloud, id: 0, name: String(localized: "音乐云盘")) }
    static var recents: PlayContext { .init(kind: .recents, id: 0, name: String(localized: "最近播放")) }
    static var heartbeat: PlayContext { .init(kind: .heartbeat, id: 0, name: String(localized: "心动模式")) }
    static var fm: PlayContext { .init(kind: .fm, id: 0, name: String(localized: "私人漫游")) }

    /// Identity is the place, not its current title — a renamed playlist is
    /// still the same entry in the recents list.
    static func == (lhs: PlayContext, rhs: PlayContext) -> Bool {
        lhs.kind == rhs.kind && lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(id)
    }
}

enum RightPanel {
    case lyrics, queue
}

/// The playback engine: queue, shuffle/repeat, personal FM, URL resolution,
/// lyrics, scrobbling. Modeled on YesPlayMusic's Player class, backed by AVPlayer.
/// High-frequency playback position, isolated so per-tick updates only
/// re-render the scrubbers/lyrics that observe it — not every view holding
/// the PlayerService.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var progress: TimeInterval = 0
}

/// Which lyric line is current.
///
/// Every lyric view used to derive this itself, which meant observing the clock
/// and re-rendering on every tick just to discover the line hadn't changed —
/// and for the now-playing page, whose body is the whole immersive layout, that
/// was five full re-evaluations a second. Computing it once here and publishing
/// only on a change turns that into one re-render per lyric line.
@MainActor
final class LyricsCursor: ObservableObject {
    @Published var activeIndex: Int?
}

@MainActor
final class PlayerService: ObservableObject {
    static let shared = PlayerService()

    // MARK: - Observable state

    @Published private(set) var queue: [Track] = []
    @Published private(set) var shuffledQueue: [Track] = []
    /// The AutoMix order's working list: `queue` with the decided next track
    /// spliced to `currentIndex + 1` as each pick is made.
    ///
    /// Materializing the choice into a list — rather than teaching the advance
    /// path a second way to find "next" — is what keeps `currentIndex`
    /// meaningful. `advanceToNext`, `previous`, `adoptTransitionedTrack` and
    /// `upcomingTracks` are the code they always were, and predev §2.1's
    /// display contract ("only the decided next is shown reordered; the rest
    /// stays list order") falls out of the splice rather than needing its own
    /// rule.
    @Published private(set) var autoMixQueue: [Track] = []
    @Published private(set) var playNextList: [Track] = []
    @Published private(set) var currentIndex = -1
    @Published private(set) var currentTrack: Track?
    @Published private(set) var source: PlaySource = .none
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var servedQuality: String?
    @Published private(set) var unblockSource: String?
    @Published private(set) var isTrial = false
    let clock = PlaybackClock()
    let lyricsCursor = LyricsCursor()
    /// Passthrough to the clock so existing `progress` reads/writes keep working.
    var progress: TimeInterval {
        get { clock.progress }
        set { clock.progress = newValue }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "player.repeat") }
    }

    /// Which order the player walks its queue in (predev §2.1). The three
    /// states are mutually exclusive by construction — there is one value —
    /// and none of them ever reorders `queue` itself, so leaving a mode always
    /// restores the list the user gave us.
    @Published private(set) var queueOrder: QueueOrder = .listed
    /// The old two-state name, kept as a read-only derivation so every call
    /// site that only ever asked "is shuffle on" — the Dock menu, the two
    /// transport bars, the persisted state — keeps working unchanged.
    var shuffleEnabled: Bool { queueOrder == .shuffled }
    @Published var volume: Float = 1 {
        didSet {
            engine.outputVolume = volume
            UserDefaults.standard.set(volume, forKey: "player.volume")
        }
    }

    @Published private(set) var isFMMode = false
    @Published private(set) var fmUpcoming: [Track] = []
    /// Where playback was most recently started from, newest first —
    /// surfaced as "Recently Played" in the Dock menu.
    @Published private(set) var recentContexts: [PlayContext] = []
    @Published private(set) var lyrics: ParsedLyrics?
    @Published var activePanel: RightPanel?
    @Published var showNowPlaying = false

    /// The list the player is walking through.
    var activeQueue: [Track] {
        switch queueOrder {
        case .listed: return queue
        case .shuffled: return shuffledQueue
        case .autoMix: return autoMixQueue
        }
    }

    var upcomingTracks: [Track] {
        guard !activeQueue.isEmpty, currentIndex >= 0 else { return playNextList }
        let rest = activeQueue.suffix(from: min(currentIndex + 1, activeQueue.count))
        return playNextList + Array(rest.prefix(200))
    }

    var hasCurrentTrack: Bool { currentTrack != nil }

    // MARK: - Engine

    private let engine = PlaybackEngine()
    /// The deck currently carrying the audible track; hand-overs flip it.
    private var activeDeck: Deck = .a
    /// The active deck has a source loaded (file or progressive stream).
    private var deckLoaded = false
    /// The loaded source is a complete local file, so the engine can seek
    /// sample-accurately and repeat-one can restart in place.
    private var hasLocalFile = false
    /// Cache entry for the source now playing; nil for trial fragments,
    /// which are never cached.
    private var currentCacheKey: AudioCache.Key?
    private var currentRemoteURL: URL?
    private var progressTimer: Timer?

    /// Live playback position straight off the deck, for smooth per-frame
    /// karaoke highlighting (the published `progress` is intentionally coarse —
    /// it only moves when the scrubber would visibly move).
    ///
    /// Falls back to `progress` whenever no deck is carrying a source, so a
    /// paused or unloaded player still reports where the playhead sits.
    var livePlaybackTime: TimeInterval {
        guard deckLoaded else { return progress }
        let t = engine.position(of: activeDeck)
        return t.isFinite ? t : progress
    }
    private var resolveGeneration = 0
    /// True while the engine is paused by us (togglePlayPause/pause/
    /// interruption). When false, "resume" must re-issue play() instead —
    /// engine.resume() is a no-op on a drained or never-paused deck.
    private var enginePaused = false

    // Auto-advance pipeline: the next track is resolved, downloaded (and
    // later analyzed) while the current one plays, then armed on the other
    // deck so the engine can hand over without touching the network.
    private struct PrefetchedNext {
        let track: Track
        let key: AudioCache.Key
        let localURL: URL
        let level: String?
        let unblockSource: String?
        var analysis: TrackAnalysis?
    }

    private var prefetchTask: Task<Void, Never>?
    private var prefetchedNext: PrefetchedNext?
    private var transitionArmed = false
    private var pendingTransitionTrack: Track?
    /// The plan the engine is currently holding, kept so the stem pre-render
    /// knows which seam it is rendering for (and notices when a re-plan moves
    /// it). Nil whenever no hand-over is armed.
    private var armedPlan: PlannedTransition?
    /// The complete local file of the track now playing, when there is one —
    /// the outgoing source a stem pre-render reads.
    private var currentLocalURL: URL?
    /// Beat/energy analysis of the track now playing, once its full file is
    /// on disk. Feeds the outgoing side of TransitionPlanner.
    private var currentAnalysis: TrackAnalysis?
    /// Raw LRC body of the track now playing, kept only so the `.lrc` sidecar
    /// can be written whenever the local file lands — the words and the file
    /// arrive in either order (streamed first play, cache hit, hand-over).
    private var currentLyricLRC: String?
    private var consecutiveFailures = 0
    private var scrobbled = false
    private var startScrobbled = false

    private init() {
        volume = UserDefaults.standard.object(forKey: "player.volume") as? Float ?? 0.8
        engine.outputVolume = volume
        repeatMode = UserDefaults.standard.string(forKey: "player.repeat")
            .flatMap(RepeatMode.init) ?? .off

        // The playing indicator's band levels, straight off the engine's mixer:
        // installed once here and never touched again, so no track change, seek
        // or hand-over has to think about it. The closure runs on the audio
        // thread and only writes floats into a preallocated store.
        engine.setOutputSampleSink { buffer in
            AudioSpectrum.shared.ingest(buffer)
        }

        #if os(iOS)
        // The engine configures the AVAudioSession lazily on first start.

        // Resume after interruptions (phone calls, WeChat voice messages, …).
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleAudioInterruption(note)
            }
        }
        // Pause when the output route disappears (headphones unplugged).
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
                      reason == .oldDeviceUnavailable, self.isPlaying else { return }
                self.pause()
            }
        }
        #endif

        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The AutoMix debug panel refreshes off this tick rather than a
                // timer of its own, so a closed window costs exactly one Bool
                // test here. It runs before the guard below because a paused or
                // buffering player is precisely when the panel is being read.
                if AutoMixDebugModel.shared.isActive { self.publishDebugNow() }
                // The queue-order pick rides this tick for the same reason:
                // with the mode off it is one optional test, and with it on
                // there is no second timer to own.
                self.updateAutoMixPick()
                guard self.isPlaying, self.deckLoaded, !self.isScrubbing else { return }
                let seconds = self.engine.position(of: self.activeDeck)
                guard seconds.isFinite else { return }

                // Lyrics need this cadence to stay in sync; the cursor itself
                // only publishes when the line actually changes.
                self.updateLyricsCursor(at: seconds)

                // The scrubber does not. Publishing the position every tick
                // re-renders it — and SwiftUI rebuilds the display list for the
                // whole tree each time — to move the thumb a fraction of a
                // pixel. Half a second is still smoother than the eye needs.
                if abs(seconds - self.progress) > 0.45 {
                    self.progress = seconds
                    NowPlayingManager.shared.updateElapsed(seconds, rate: 1)
                }
                self.updateStemPrerender()
            }
        }
        // .common keeps the clock ticking through menu tracking and window
        // drags, where the default run-loop mode starves plain timers.
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer

        Task { [weak self] in
            guard let events = self?.engine.events else { return }
            for await event in events {
                guard let self else { return }
                self.handleEngineEvent(event)
            }
        }

        NowPlayingManager.shared.attach(to: self)
        restoreState()
    }

    /// Set while the user drags the seek bar so the time observer doesn't fight the thumb.
    var isScrubbing = false

    #if os(iOS)
    private var wasPlayingBeforeInterruption = false

    private func handleAudioInterruption(_ note: Notification) {
        guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying {
                // The system already silenced us; mark the engine paused too,
                // or the .ended resume() below is a guarded no-op.
                engine.pause()
                enginePaused = true
                isPlaying = false
                NowPlayingManager.shared.updateElapsed(progress, rate: 0)
            }
        case .ended:
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            guard wasPlayingBeforeInterruption, options.contains(.shouldResume) else { return }
            wasPlayingBeforeInterruption = false
            try? AVAudioSession.sharedInstance().setActive(true)
            engine.resume()
            enginePaused = false
            isPlaying = true
            NowPlayingManager.shared.updateElapsed(progress, rate: 1)
        @unknown default:
            break
        }
    }
    #endif

    // MARK: - Entry points

    /// - Parameter context: the place these tracks came from. Supplying it
    ///   lists that place in the Dock menu's recently played section; callers
    ///   playing an ad-hoc selection (search results, a single track) omit it.
    func play(tracks: [Track], source: PlaySource, startAt track: Track? = nil,
              context: PlayContext? = nil) {
        guard !tracks.isEmpty else { return }
        if let context { recordRecent(context) }
        isFMMode = false
        queue = tracks
        self.source = source
        playNextList.removeAll()
        let startTrack = track ?? tracks[0]
        queueOrderSelector?.reset()
        switch queueOrder {
        case .listed:
            currentIndex = tracks.firstIndex(where: { $0.id == startTrack.id }) ?? 0
        case .shuffled:
            reshuffle(keeping: startTrack)
            currentIndex = 0
        case .autoMix:
            reorderForAutoMix(keeping: startTrack)
            currentIndex = 0
        }
        startPlaying(activeQueue[currentIndex])
    }

    func playTrack(_ track: Track) {
        if let idx = activeQueue.firstIndex(where: { $0.id == track.id }) {
            currentIndex = idx
            startPlaying(track)
        } else {
            play(tracks: [track], source: .none)
        }
    }

    /// Insert a track right after the current one.
    func addToPlayNext(_ track: Track, playNow: Bool = false) {
        playNextList.append(track)
        if playNow || currentTrack == nil {
            advanceToNext(userInitiated: true)
        } else {
            ToastCenter.shared.show(String(localized: "已添加到下一首播放"))
            schedulePrefetch()
        }
    }

    func togglePlayPause() {
        guard let track = currentTrack else { return }
        if isPlaying {
            engine.pause()
            enginePaused = true
            isPlaying = false
            AudioSpectrum.shared.reset()
        } else if !deckLoaded {
            // Restored session: re-resolve the source.
            startPlaying(track, indexUnchanged: true)
            return
        } else if enginePaused {
            engine.resume()
            enginePaused = false
            isPlaying = true
        } else {
            // The deck drained (queue end) or was loaded without playing —
            // resume() would be a no-op; re-issue play from where we are.
            engine.play(deck: activeDeck, from: min(progress, max(0, duration - 0.1)))
            isPlaying = true
        }
        NowPlayingManager.shared.updateElapsed(progress, rate: isPlaying ? 1 : 0)
    }

    func pause() {
        engine.pause()
        enginePaused = true
        isPlaying = false
        AudioSpectrum.shared.reset()
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
    }

    func next() {
        advanceToNext(userInitiated: true)
    }

    func previous() {
        if isFMMode { return }
        if progress > 4 || activeQueue.isEmpty {
            seek(to: 0)
            return
        }
        var idx = currentIndex - 1
        if idx < 0 {
            guard repeatMode == .all else {
                seek(to: 0)
                return
            }
            idx = activeQueue.count - 1
        }
        currentIndex = idx
        startPlaying(activeQueue[idx])
    }

    /// Recomputes the current lyric line, publishing only on a change.
    /// The lead makes a line light up just before it is sung.
    private func updateLyricsCursor(at seconds: TimeInterval) {
        let index = lyrics?.activeIndex(at: seconds + 0.2)
        if index != lyricsCursor.activeIndex {
            lyricsCursor.activeIndex = index
        }
    }

    /// `completion` runs once the playhead is at `seconds`. The engine seeks
    /// synchronously, so it runs before this returns — the parameter exists for
    /// the AVPlayer-shaped call sites in the UI.
    func seek(to seconds: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        // An armed/overlapping hand-over is anchored to the old timeline —
        // cancel it, seek, then re-arm from the prefetched file.
        //
        // The re-armed plan still carries the out point the planner computed
        // for the whole track, which the seek may have just jumped past. The
        // engine (resolvePlanLocked) degrades such a plan to a tail-anchored
        // crossfade or to gapless instead of firing it on the spot — a seek
        // into the transition window must never start the next song.
        let wasArmed = transitionArmed
        if wasArmed { disarmTransition() }
        progress = seconds
        updateLyricsCursor(at: seconds)
        engine.seek(deck: activeDeck, to: seconds)
        NowPlayingManager.shared.updateElapsed(seconds, rate: isPlaying ? 1 : 0)
        if wasArmed { armTransitionIfReady() }
        completion?()
    }

    func toggleShuffle() {
        setQueueOrder(shuffleEnabled ? .listed : .shuffled)
    }

    /// The AutoMix order's own switch. Mutual exclusion with shuffle is not a
    /// rule enforced here — it is `QueueOrder` having one value at a time.
    func toggleAutoMixOrder() {
        setQueueOrder(queueOrder == .autoMix ? .listed : .autoMix)
    }

    /// Whether the AutoMix order can do anything at all. It picks by planning,
    /// and planning needs analyses — which iOS and an AutoMix-off player never
    /// compute. The UI hides the switch rather than offering an inert one.
    var autoMixOrderAvailable: Bool { analysisWanted }

    func setQueueOrder(_ order: QueueOrder) {
        guard !isFMMode, queueOrder != order else { return }
        let current = currentTrack
        queueOrder = order
        syncQueueOrderSelector()
        autoMixPickCommitted = false
        switch order {
        case .listed:
            shuffledQueue = []
            autoMixQueue = []
            if let current {
                currentIndex = queue.firstIndex(where: { $0.id == current.id }) ?? 0
            }
        case .shuffled:
            autoMixQueue = []
            guard let current else { break }
            reshuffle(keeping: current)
            currentIndex = 0
        case .autoMix:
            shuffledQueue = []
            guard let current else { break }
            reorderForAutoMix(keeping: current)
            currentIndex = 0
        }
        persistState()
        schedulePrefetch()
    }

    func cycleRepeatMode() {
        guard !isFMMode else { return }
        repeatMode = repeatMode.next
        // Repeat-one forbids auto hand-overs; the other modes change what
        // comes after the final queue entry.
        schedulePrefetch()
    }

    /// Single-button mode cycle for the iOS minimal transport row:
    /// sequential → loop all → loop one → shuffle → sequential.
    func cyclePlaybackMode() {
        guard !isFMMode else { return }
        if shuffleEnabled {
            toggleShuffle()
            repeatMode = .off
        } else {
            switch repeatMode {
            case .off:
                repeatMode = .all
            case .all:
                repeatMode = .one
            case .one:
                repeatMode = .off
                toggleShuffle()
            }
        }
    }

    /// Jump to a track in the upcoming list (queue panel click).
    func jumpTo(_ track: Track) {
        if let nextIdx = playNextList.firstIndex(where: { $0.id == track.id }) {
            playNextList.removeSubrange(0...nextIdx)
            startPlaying(track, indexUnchanged: true)
            return
        }
        if let idx = activeQueue.firstIndex(where: { $0.id == track.id }) {
            currentIndex = idx
            startPlaying(track)
        }
    }

    func removeFromUpcoming(_ track: Track) {
        if let idx = playNextList.firstIndex(where: { $0.id == track.id }) {
            playNextList.remove(at: idx)
            return
        }
        if let idx = queue.firstIndex(where: { $0.id == track.id }),
           idx != currentIndex || queueOrder != .listed {
            queue.remove(at: idx)
        }
        if let idx = shuffledQueue.firstIndex(where: { $0.id == track.id }) {
            shuffledQueue.remove(at: idx)
        }
        if let idx = autoMixQueue.firstIndex(where: { $0.id == track.id }), idx != currentIndex {
            autoMixQueue.remove(at: idx)
        }
        // The chain may have been planning around the track that just left.
        refreshAutoMixLookahead(force: true)
        schedulePrefetch()
    }

    // MARK: - Personal FM

    func startFM() {
        guard !isFMMode || !isPlaying else { return }
        recordRecent(.fm)
        isFMMode = true
        queueOrder = .listed
        syncQueueOrderSelector()
        repeatMode = .off
        queue = []
        shuffledQueue = []
        autoMixQueue = []
        playNextList = []
        currentIndex = -1
        source = .none
        Task { await fmAdvance() }
    }

    func fmNext() {
        guard isFMMode else { return }
        Task { await fmAdvance() }
    }

    func fmTrash() {
        guard isFMMode, let track = currentTrack else { return }
        Task {
            await fmAdvance()
            try? await NeteaseAPI.fmTrash(id: track.id)
        }
    }

    private func fmAdvance() async {
        if fmUpcoming.isEmpty {
            for attempt in 0..<3 {
                if let tracks = try? await NeteaseAPI.personalFM(), !tracks.isEmpty {
                    fmUpcoming = tracks
                    break
                }
                if attempt == 2 {
                    ToastCenter.shared.show(String(localized: "获取私人漫游数据失败"))
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        guard !fmUpcoming.isEmpty else { return }
        let track = fmUpcoming.removeFirst()
        startPlaying(track, indexUnchanged: true)
        if fmUpcoming.count < 1 {
            if let more = try? await NeteaseAPI.personalFM() {
                fmUpcoming.append(contentsOf: more)
            }
        }
    }

    // MARK: - Advancing

    private func advanceToNext(userInitiated: Bool) {
        if isFMMode {
            Task { await fmAdvance() }
            return
        }
        if !playNextList.isEmpty {
            let track = playNextList.removeFirst()
            startPlaying(track, indexUnchanged: true)
            return
        }
        guard !activeQueue.isEmpty else { return }
        var idx = currentIndex + 1
        if idx >= activeQueue.count {
            guard repeatMode == .all else {
                if userInitiated {
                    ToastCenter.shared.show(String(localized: "已经是最后一首了"))
                } else {
                    isPlaying = false
                    NowPlayingManager.shared.updateElapsed(progress, rate: 0)
                }
                return
            }
            idx = 0
        }
        currentIndex = idx
        startPlaying(activeQueue[idx])
    }

    private func handleItemEnded() {
        scrobbleIfNeeded(completed: true)
        if repeatMode == .one, !isFMMode {
            scrobbled = false
            if hasLocalFile {
                progress = 0
                engine.play(deck: activeDeck, from: 0)
                isPlaying = true
                NowPlayingManager.shared.updateElapsed(0, rate: 1)
            } else if let track = currentTrack {
                // A drained stream can't restart in place; re-resolve (the
                // second pass usually hits the cache the first one committed).
                startPlaying(track, indexUnchanged: true)
            }
            return
        }
        advanceToNext(userInitiated: false)
    }

    // MARK: - Source resolution

    /// Void an armed hand-over, keeping the prefetched file/analysis around
    /// so the transition can be re-armed (post-seek) without re-downloading.
    private func disarmTransition() {
        engine.cancelScheduledTransition()
        transitionArmed = false
        pendingTransitionTrack = nil
        armedPlan = nil
        AutoMixDebugModel.shared.setPlan(nil)
        // Whatever the pre-render was aiming at is void: a re-arm re-derives
        // the plan, and `updateStemPrerender` starts again from there.
        cancelStemPrerender()
    }

    private func startPlaying(_ track: Track, indexUnchanged: Bool = false) {
        // Any armed hand-over is void: this is a hard track change.
        disarmTransition()
        engine.stop(deck: activeDeck.other)
        prefetchTask?.cancel()
        prefetchedNext = nil
        currentAnalysis = nil
        currentLocalURL = nil
        // A new track is a new decision round for the queue-order mode: the
        // escalation restarts from nothing admitted, on top of the (now
        // richer) pool of everything analyzed so far.
        autoMixPickCommitted = false
        queueOrderSelector?.beginPick()
        AutoMixDebugModel.shared.clearNext()
        isBuffering = false
        enginePaused = false

        scrobbleIfNeeded(completed: false)
        currentTrack = track
        progress = 0
        duration = track.duration
        servedQuality = nil
        unblockSource = nil
        isTrial = false
        lyrics = nil
        currentLyricLRC = nil
        scrobbled = false
        startScrobbled = false
        isPlaying = true
        lyricsCursor.activeIndex = nil
        // Before the URL is even resolved: holds the bars still rather than
        // letting them fall back to the decorative animation for the moment it
        // takes to find out whether this source can be tapped.
        AudioSpectrum.shared.beginPreparing()
        resolveGeneration += 1
        let generation = resolveGeneration

        NowPlayingManager.shared.updateMetadata(for: track, duration: track.duration)
        persistState()

        Task {
            await resolveAndLoad(track, generation: generation)
        }
        Task {
            await loadLyrics(for: track, generation: generation)
        }
    }

    private struct ResolvedSource {
        let url: URL
        let key: AudioCache.Key
        let level: String?
        let unblockSource: String?
        let isTrial: Bool
        let durationMS: Int?
    }

    /// The full URL-resolution chain (quality fallback → https upgrade →
    /// unblock rescue) plus cache-key derivation — shared by playback and
    /// prefetch so both always derive identical keys. Pure: no toasts, no
    /// state changes.
    private func resolveSource(for track: Track) async -> ResolvedSource? {
        let quality = SettingsManager.shared.audioQuality.rawValue
        var data = try? await NeteaseAPI.songURL(ids: [track.id], level: quality).first
        if data?.url == nil, quality != AudioQuality.standard.rawValue {
            data = try? await NeteaseAPI.songURL(ids: [track.id], level: AudioQuality.standard.rawValue).first
        }
        var url: URL?
        var unblock: String?
        if let urlString = data?.url {
            url = URL(string: urlString.replacingOccurrences(of: "http://", with: "https://"))
        }
        // NetEase refused — try third-party sources (UnblockNeteaseMusic-style).
        if url == nil || data?.freeTrialInfo != nil, SettingsManager.shared.enableUnblock {
            if let unblocked = await UnblockService.resolve(track) {
                url = unblocked.url
                unblock = unblocked.source
                data = nil
            }
        }
        guard let url else { return nil }
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension.lowercased()
        return ResolvedSource(
            url: url,
            key: AudioCache.Key(trackID: track.id, level: data?.level ?? quality,
                                source: unblock.map { "unblock:\($0)" } ?? "netease",
                                fileExtension: ext),
            level: data?.level,
            unblockSource: unblock,
            isTrial: data?.freeTrialInfo != nil,
            durationMS: data?.time)
    }

    private func resolveAndLoad(_ track: Track, generation: Int) async {
        let resolved = await resolveSource(for: track)
        guard generation == resolveGeneration else { return }

        guard let resolved else {
            consecutiveFailures += 1
            let reason = track.playability(privilege: nil,
                                           isLoggedIn: AccountStore.shared.isLoggedIn,
                                           vipType: AccountStore.shared.vipType).reason
            ToastCenter.shared.show(String(localized: "《\(track.name)》无法播放\(reason.map { "：\($0)" } ?? "")"))
            if consecutiveFailures < 5 {
                advanceToNext(userInitiated: false)
            } else {
                isPlaying = false
            }
            return
        }

        consecutiveFailures = 0
        servedQuality = resolved.level
        unblockSource = resolved.unblockSource
        if let source = resolved.unblockSource {
            ToastCenter.shared.show(String(localized: "已使用第三方音源：\(source)"))
        }
        if resolved.isTrial {
            isTrial = true
            ToastCenter.shared.show(String(localized: "VIP 歌曲，当前为试听片段"))
        }

        let key = resolved.key
        currentCacheKey = resolved.isTrial ? nil : key
        currentRemoteURL = resolved.url

        engine.stop(deck: activeDeck)
        deckLoaded = true
        hasLocalFile = false

        if !resolved.isTrial {
            var local = await AudioCache.shared.cachedFileURL(for: key)
            if local == nil, let inflight = await AudioCache.shared.activeDownload(for: key) {
                // A prefetch of this very track is mid-flight — wait for it
                // instead of opening a second transfer of the same file.
                isBuffering = true
                local = try? await inflight.value
                isBuffering = false
            }
            guard generation == resolveGeneration else { return }
            // A cached sidecar (this track has been heard before) lets the deck
            // open at its compensated level right away. On a miss the trim is 0
            // and stays 0 for this play: `ensureCurrentAnalysis` below will
            // compute and persist the analysis, but applying it now would be an
            // audible jump mid-song, so it takes effect from the next load.
            let cachedAnalysis = analysisWanted
                ? await AudioCache.shared.loadAnalysis(for: key) : nil
            guard generation == resolveGeneration else { return }
            if let local,
               let fileDuration = try? engine.loadFile(
                   at: local, on: activeDeck, trimDB: loudnessTrimDB(for: cachedAnalysis),
                   peakDBFS: cachedAnalysis?.peakDBFS) {
                hasLocalFile = true
                currentLocalURL = local
                persistCurrentLyricsSidecar()
                engine.play(deck: activeDeck, from: 0)
                isPlaying = true
                AudioSpectrum.shared.markTapped()
                scrobbleStartIfNeeded(track)
                duration = fileDuration
                NowPlayingManager.shared.updateMetadata(for: track, duration: fileDuration)
                ensureCurrentAnalysis(key: key, fileURL: local)
                schedulePrefetch()
                return
            }
            // Unreadable cache entry — fall through to streaming.
        }
        guard generation == resolveGeneration else { return }

        let partURL: URL
        if resolved.isTrial {
            // Trial fragments never enter the cache; the mirror write goes to
            // a temp file the OS cleans up.
            partURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("kumone-trial-\(track.id).part")
        } else {
            partURL = AudioCache.shared.partFileURL(for: key)
        }
        // Buffering until the first decoded chunk lands (streamResumed).
        isBuffering = true
        engine.startStreaming(from: resolved.url, formatHint: key.fileExtension,
                              writingTo: partURL, on: activeDeck)
        engine.play(deck: activeDeck, from: 0)
        isPlaying = true
        AudioSpectrum.shared.markTapped()
        scrobbleStartIfNeeded(track)

        if let time = resolved.durationMS, time > 0 {
            duration = TimeInterval(time) / 1000
            NowPlayingManager.shared.updateMetadata(for: track, duration: duration)
        }
        schedulePrefetch()
    }

    // MARK: - Engine events

    private func handleEngineEvent(_ event: PlaybackEngineEvent) {
        switch event {
        case .deckFinished(let deck):
            guard deck == activeDeck else { return }
            handleItemEnded()
        case .streamStalled(let deck):
            if deck == activeDeck { isBuffering = true }
        case .streamResumed(let deck):
            if deck == activeDeck { isBuffering = false }
        case .streamDownloadCompleted(let deck):
            guard deck == activeDeck, let key = currentCacheKey else { return }
            let generation = resolveGeneration
            Task { [weak self] in
                guard let final = try? await AudioCache.shared.commitPartFile(for: key),
                      let self, generation == self.resolveGeneration else { return }
                // The complete file just landed — which is exactly what
                // `currentLocalURL` means. The deck keeps playing its stream
                // source (so `hasLocalFile` stays honest), but everything that
                // reads the *file* — the stem pre-render's outgoing side, the
                // pick's lyric line-ends, and the queue-order politeness gate —
                // can start now instead of waiting for the next track.
                self.currentLocalURL = final
                self.ensureCurrentAnalysis(key: key, fileURL: final)
                // The progressive mirror just became a complete file: the words
                // fetched at the start of the song now have something to sit by.
                self.persistCurrentLyricsSidecar(audio: final)
                // The prefetch pipeline may have deferred while this track
                // was still streaming (same-track repeat) — re-run it.
                self.schedulePrefetch()
            }
        case .streamFailed(let deck, _):
            guard deck == activeDeck else { return }
            handleStreamFailure()
        case .transitionMidpoint(_, let to, let outcome):
            // Freeze the seam *before* adopting: from here on `currentTrack`
            // is the incoming song and the outgoing one is gone.
            recordDebugSeam(outcome)
            adoptTransitionedTrack(on: to)
        case .transitionCompleted:
            transitionArmed = false
            armedPlan = nil
            AutoMixDebugModel.shared.setPlan(nil)
            cancelStemPrerender()
            schedulePrefetch()
        }
    }

    /// Progressive playback died (parse error, mid-file network loss, format
    /// the stream parser can't resync): download the whole file instead and
    /// resume near where it stopped.
    private func handleStreamFailure() {
        if isPlaying { isBuffering = true }
        let generation = resolveGeneration
        let resumeAt = progress
        guard let key = currentCacheKey, let remote = currentRemoteURL,
              let track = currentTrack else {
            streamFallbackFailed()
            return
        }
        Task {
            do {
                let local = try await AudioCache.shared.download(from: remote, key: key)
                guard generation == resolveGeneration else { return }
                // Mid-song recovery: keep the level exactly where the listener
                // has been hearing it (the stream started at unity), so the
                // fallback is inaudible.
                let fileDuration = try engine.loadFile(at: local, on: activeDeck, trimDB: 0)
                hasLocalFile = true
                currentLocalURL = local
                persistCurrentLyricsSidecar()
                isBuffering = false
                duration = fileDuration
                if isPlaying {
                    engine.play(deck: activeDeck, from: min(resumeAt, max(0, fileDuration - 1)))
                } else {
                    // The user paused mid-stream: stay silent. The play
                    // button re-issues play() from `progress`.
                    enginePaused = false
                }
                NowPlayingManager.shared.updateMetadata(for: track, duration: fileDuration)
                ensureCurrentAnalysis(key: key, fileURL: local)
                schedulePrefetch()
            } catch {
                guard generation == resolveGeneration else { return }
                streamFallbackFailed()
            }
        }
    }

    private func streamFallbackFailed() {
        isBuffering = false
        consecutiveFailures += 1
        ToastCenter.shared.show(String(localized: "播放失败，已跳过"))
        if consecutiveFailures < 5 {
            advanceToNext(userInitiated: false)
        } else {
            isPlaying = false
        }
    }

    // MARK: - Auto-advance pipeline (prefetch + transitions)

    /// The track the player would advance to on its own, or nil when the
    /// hand-over must stay manual (repeat-one, trial fragment, end of queue).
    private func autoAdvanceTarget() -> Track? {
        guard !isTrial, repeatMode != .one else { return nil }
        if isFMMode { return fmUpcoming.first }
        if let next = playNextList.first { return next }
        guard !activeQueue.isEmpty, currentIndex >= 0 else { return nil }
        let idx = currentIndex + 1
        if idx < activeQueue.count { return activeQueue[idx] }
        return repeatMode == .all ? activeQueue.first : nil
    }

    /// (Re)start the pipeline for the current auto-advance target. Call after
    /// playback starts and whenever the upcoming list changes.
    private func schedulePrefetch() {
        // AutoMix order decides *which* track is next, and until it has there
        // is nothing to prefetch: committing to the list's answer now would
        // download the wrong song and arm it before the choice was made.
        // `updateAutoMixPick` calls back in here the moment it decides — at the
        // latest at `autoMixDeadline`, which is sized so the winner still has
        // time to be downloaded, analyzed and armed.
        if autoMixPickPending {
            prefetchTask?.cancel()
            // Nilled, not just cancelled, so `autoMixMayDownload` can read it
            // as the truthful "no playback-quality transfer is running".
            prefetchTask = nil
            prefetchedNext = nil
            AutoMixDebugModel.shared.setNextTitle(
                nil, stage: .deferred("AutoMix order is still choosing"))
            return
        }
        prefetchTask?.cancel()
        let target = autoAdvanceTarget()
        if let armed = pendingTransitionTrack {
            // Already armed for the right track — the pipeline is done.
            if armed.id == target?.id { return }
            // The armed hand-over points at a track that is no longer next.
            disarmTransition()
            engine.stop(deck: activeDeck.other)
        }
        prefetchedNext = nil
        guard let target else {
            AutoMixDebugModel.shared.clearNext()
            return
        }
        AutoMixDebugModel.shared.setNextTitle(target.name, stage: .resolving)
        if target.id == currentTrack?.id, deckLoaded, !hasLocalFile {
            AutoMixDebugModel.shared.setNextStage(
                .deferred("same track still streaming into the cache"))
            // The next track IS the one still streaming into the cache
            // (single-track repeat-all). A parallel download would race the
            // .part mirror; streamDownloadCompleted re-runs this instead.
            return
        }
        let generation = resolveGeneration
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            guard let resolved = await self.resolveForPrefetch(target) else {
                AutoMixDebugModel.shared.setNextStage(.failed("no playable source"))
                return
            }
            guard !Task.isCancelled, generation == self.resolveGeneration else { return }
            AutoMixDebugModel.shared.setNextStage(.downloading)
            guard let local = try? await AudioCache.shared.download(from: resolved.url, key: resolved.key)
            else {
                AutoMixDebugModel.shared.setNextStage(.failed("download failed"))
                return
            }
            guard !Task.isCancelled, generation == self.resolveGeneration else { return }
            AutoMixDebugModel.shared.setNextStage(.downloaded)
            // The words next: this track is about to be the *incoming* side of
            // a seam and, one song later, the outgoing side whose lyric line
            // decides where a vocal exchange hands over. One small JSON call.
            Task.detached(priority: .utility) { [id = target.id] in
                await LyricsSidecar.fetchAndWrite(trackID: id, for: local)
            }
            AutoMixDebugModel.shared.setNextStage(.analyzing)
            let analysis = await self.analysis(for: resolved.key, fileURL: local)
            guard !Task.isCancelled, generation == self.resolveGeneration,
                  self.autoAdvanceTarget()?.id == target.id else { return }
            // The `.lrc` write above is detached, so this may read a beat before
            // the file lands; the sidecar row is re-read on the next re-plan.
            AutoMixDebugModel.shared.setNextAnalysis(analysis, localURL: local)
            self.prefetchedNext = PrefetchedNext(
                track: target, key: resolved.key, localURL: local,
                level: resolved.level, unblockSource: resolved.unblockSource, analysis: analysis)
            self.armTransitionIfReady()
        }
    }

    /// Prefetch variant of the shared resolver: trial fragments resolve to
    /// nil (they can't be cached, so they can't be armed either).
    private func resolveForPrefetch(_ track: Track) async -> ResolvedSource? {
        guard let resolved = await resolveSource(for: track), !resolved.isTrial else { return nil }
        return resolved
    }

    /// Load the prefetched track on the idle deck and pre-arm the hand-over.
    private func armTransitionIfReady() {
        guard !transitionArmed, let next = prefetchedNext else { return }
        let incoming = activeDeck.other
        guard (try? engine.loadFile(at: next.localURL, on: incoming,
                                    trimDB: loudnessTrimDB(for: next.analysis),
                                    peakDBFS: next.analysis?.peakDBFS)) != nil else {
            prefetchedNext = nil
            AutoMixDebugModel.shared.setNextStage(.failed("incoming deck would not load the file"))
            return
        }
        let planned = makeTransitionPlan(for: next)
        engine.scheduleTransition(planned, from: activeDeck, to: incoming)
        armedPlan = planned
        transitionArmed = true
        pendingTransitionTrack = next.track
        publishDebugPlan(planned, next: next)
    }

    private func makeTransitionPlan(for next: PrefetchedNext) -> PlannedTransition {
        #if os(iOS)
        return .plain(.gapless)
        #else
        guard SettingsManager.shared.automixEnabled else { return .plain(.gapless) }
        if currentAnalysis == nil || next.analysis == nil {
            // Analyses not ready (first listen, current track still
            // streaming): a plain crossfade still beats a hard cut.
            //
            // No analysis means no beat grid, so this is the one refusal the
            // force override cannot argue with — and the one a listener is most
            // likely to hit, by flipping the toggle on a track heard for the
            // first time. Say so rather than leaving the badge on next to a
            // crossfade.
            if AutoMixDebugModel.shared.overrides.forceBeatMatch {
                AutoMixDebugModel.shared.setForceNote(
                    "force requested but impossible: "
                        + (currentAnalysis == nil ? "the playing track" : "the next track")
                        + " has no analysis yet")
            }
            guard duration > 45 else { return .plain(.gapless) }
            let fade: TimeInterval = 6
            return .plain(.crossfade(duration: fade,
                                     outPoint: max(duration - fade, duration * 0.6),
                                     inPoint: 0))
        }
        // Stem availability follows the process: the launcher installs a
        // separator only when the model and metallib are actually usable
        // (macOS, checkpoint on disk). Without one, `.none` keeps this the
        // byte-identical whole-mix path.
        let stems: StemAvailability = StemSeparation.isAvailable ? .ready : .none
        // Lyric line ends for the outgoing track, so the planner can pull its
        // out point back onto a full stop instead of cutting mid-line. The
        // `.lrc` sits next to the cached audio (written by `LyricsSidecar` on
        // the prefetch path), so this is a few-KB synchronous read on the main
        // actor — the same read `VocalExchange.compile` already does at
        // plan-adjacent time, run once per seam, minutes apart. Off the main
        // actor it would have to be awaited, which would turn arming into an
        // async step for no measurable gain. Missing file → empty → the
        // pre-structure decision, unchanged.
        let context = TransitionPlanner.PlanContext(
            outgoingLyricLineEnds: currentLocalURL
                .map { Audition.Lyrics.lineEnds(for: $0) } ?? [])
        let config = plannerConfig
        guard AutoMixDebugModel.shared.overrides.forceBeatMatch else {
            AutoMixDebugModel.shared.setForceNote(nil)
            return TransitionPlanner.plan(outgoing: currentAnalysis, incoming: next.analysis,
                                          stems: stems, config: config, context: context)
        }
        // Forced: take the ledger too. Under the override every admission gate
        // abstains, so whatever `blocker` names is one of the physical
        // requirements the panel refuses to fake — which is exactly the sentence
        // the listener needs when the seam comes out as a crossfade anyway.
        // The traced overload decides identically; it only costs the ledger,
        // and only on a seam somebody asked to force.
        var trace: PlanTrace? = PlanTrace()
        let planned = TransitionPlanner.plan(
            outgoing: currentAnalysis, incoming: next.analysis, stems: stems,
            config: config, context: context, trace: &trace)
        if case .beatMatched = planned.plan {
            AutoMixDebugModel.shared.setForceNote(nil)
        } else {
            AutoMixDebugModel.shared.setForceNote(
                trace?.blocker.map { "force requested but impossible: \($0.label) — \($0.detail)" }
                    ?? "force requested but impossible: no beat-matched plan and no blocking gate")
        }
        return planned
        #endif
    }

    // MARK: - Stem pre-render

    /// How far ahead of the splice the pre-render is started, and the point at
    /// which an unfinished one is abandoned.
    ///
    /// A separation pass runs at roughly realtime per side, so a 15 s hand-over
    /// wanting both sides is ~30 s of work plus a second of rendering: a minute
    /// of lead is comfortable, and the guard is there so a machine that is
    /// busier than that never delays a hand-over — it simply gets the live one.
    private static let stemPrerenderLead: TimeInterval = 60
    private static let stemPrerenderGuard: TimeInterval = 5

    /// Separation runs at roughly realtime **per side**, and a segment wants
    /// both sides of the seam.
    private static let stemPrerenderSidesPerSeam: Double = 2
    /// Slack on top of the separation estimate: the render pull loop, the file
    /// writes, and a machine that is doing other things at the same time.
    private static let stemPrerenderMargin: TimeInterval = 15

    /// How much runway one seam's pre-render actually needs.
    ///
    /// This is the arithmetic that was hiding inside the flat 60 s lead — "a
    /// 15 s hand-over wanting both sides is ~30 s of work plus a second of
    /// rendering" — pulled out and made **per-seam**, so a seam that moves
    /// underneath a finished render can be judged on whether the re-render
    /// *fits* rather than on whether it is early.
    ///
    /// That distinction is the whole fix. The old code had one number doing two
    /// jobs: "not yet" and "no longer possible". A deadline-committed pick
    /// arrives late by construction — the winner still has to be re-downloaded
    /// at playback quality, re-analyzed and re-planned, which moves the seam —
    /// and the re-render was then refused for being late even when there was
    /// ample time to do it. A 16 s overlap needs 47 s; being handed 49 s is not
    /// a problem, and now it is not treated as one.
    /// `separatesStems` false is a **score-only** segment: whole-mix gain lanes,
    /// no separator consulted on either side (`WholeMixLaneLayer`). The
    /// separation term is then not small, it is *absent* — what is left is one
    /// render pass, and the margin already covers that with room to spare. This
    /// is why a cut-on-one costs the runway a 30 s overlap used to be refused
    /// for and a `.vocalExchange` still does.
    nonisolated static func stemPrerenderRunway(
        overlapDuration: TimeInterval, separatesStems: Bool = true
    ) -> TimeInterval {
        guard separatesStems else { return stemPrerenderMargin }
        return stemPrerenderSidesPerSeam * max(0, overlapDuration) + stemPrerenderMargin
    }

    private enum StemPrerenderState {
        case idle
        /// A job is running for this seam.
        case running(TransitionSegment.Signature)
        /// This seam has had its one attempt — finished, failed or abandoned.
        /// Never retried: the lead time is gone either way.
        case settled(TransitionSegment.Signature)

        var signature: TransitionSegment.Signature? {
            switch self {
            case .idle: return nil
            case .running(let s), .settled(let s): return s
            }
        }
    }

    /// A pre-render's stop switch.
    ///
    /// `Task.cancel` alone would only orphan the job: the render is a
    /// synchronous pull loop inside a detached task and a separation pass is
    /// seconds of Metal work. So cancellation is also checked where it can
    /// actually be acted on — at each separation boundary, which is where all
    /// the time goes.
    private final class PrerenderCancel: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
    }

    private var stemPrerenderTask: Task<Void, Never>?
    private var stemPrerenderCancel: PrerenderCancel?
    private var stemPrerenderState: StemPrerenderState = .idle

    /// Polled from the progress timer: start, abandon or ignore the pre-render
    /// of the armed hand-over. Cheap — a few comparisons — until the moment it
    /// starts the one background job it will ever run for a given seam.
    private func updateStemPrerender() {
        // Debug A/B: skip the render entirely so the seam is carried by the
        // live two-deck path, which is the approximation a stem hand-over
        // exists to beat. `setOverrides` tears down and re-arms when this is
        // switched on, so a segment armed a moment ago is already gone.
        if AutoMixDebugModel.shared.overrides.forceLivePath {
            AutoMixDebugModel.shared.setPrerender(
                .refused("force live path (debug override)"))
            return
        }
        guard transitionArmed, let planned = armedPlan,
              planned.style.stemTechnique != nil || planned.style.score != nil,
              let signature = TransitionSegment.Signature(plan: planned.plan),
              let outgoingURL = currentLocalURL, let next = prefetchedNext
        else { return }
        // A stem technique needs a separator; a score does not touch one. That
        // asymmetry is the whole cost story of P1 — a score-only segment is a
        // render and nothing else — so it decides both the admission above and
        // the runway below.
        let separatesStems = planned.style.stemTechnique != nil
        guard !separatesStems || StemSeparation.isAvailable else { return }

        // A re-plan (a late analysis, a degraded seam after a seek) moves the
        // splice; whatever was rendered for the old one is the wrong audio.
        if let running = stemPrerenderState.signature, running != signature {
            cancelStemPrerender()
        }
        let splice = signature.outPoint - TransitionSegmentRenderer.handoff
        // The live playhead, not the published `progress`: that one is only
        // republished when the scrubber would visibly move, so it can sit up to
        // half a second behind — half a second of runway this decision spends.
        let remaining = splice - livePlaybackTime

        switch stemPrerenderState {
        case .settled:
            return
        case .running:
            // Out of runway: drop the job and let the live path have the
            // hand-over. The engine has never been told about this segment, so
            // there is nothing to undo there.
            if remaining < Self.stemPrerenderGuard {
                stemPrerenderCancel?.cancel()
                stemPrerenderTask?.cancel()
                stemPrerenderTask = nil
                stemPrerenderState = .settled(signature)
                AutoMixDebugModel.shared.setPrerender(
                    .abandoned(String(format: "out of runway (%.1fs left)", remaining)))
            }
            return
        case .idle:
            // Too early is not a decision — come back next tick.
            guard remaining <= Self.stemPrerenderLead else { return }
            let runway = Self.stemPrerenderRunway(
                overlapDuration: signature.overlapDuration,
                separatesStems: separatesStems)
            guard remaining >= runway, remaining > Self.stemPrerenderGuard else {
                // It genuinely does not fit. Say so with the numbers and settle
                // — starting a render that cannot finish only burns Metal time
                // and abandons at the guard anyway.
                stemPrerenderState = .settled(signature)
                let why = String(
                    format: "not enough runway (%.1fs left, %.1fs needed for a %.1fs overlap)",
                    remaining, runway, signature.overlapDuration)
                AutoMixDebugModel.shared.setPrerender(.refused(why))
                PlaybackJournal.note("prerender refused \(why)")
                return
            }
            PlaybackJournal.note(String(
                format: "prerender start remaining=%.1fs runway=%.1fs overlap=%.1fs%@",
                remaining, runway, signature.overlapDuration,
                remaining < Self.stemPrerenderLead - 2
                    // Started with less than the full lead: the seam moved
                    // under a finished render, which is what a deadline-
                    // committed pick does. Worth naming — it used to be the
                    // moment the gesture silently vanished.
                    ? " late (seam moved)" : ""))
        }

        // A score-only segment never calls this, so a machine with no separator
        // installed still gets one: the provider it is handed throws if the
        // render ever asks, which for a whole-mix score it cannot.
        let provider: VocalStemProvider = StemSeparation.provider
            ?? { _ in throw StemTechniqueLayer.StemError.noProvider }
        if separatesStems, StemSeparation.provider == nil { return }
        let request = TransitionSegmentRenderer.Request(
            planned: planned, outgoingURL: outgoingURL, incomingURL: next.localURL,
            outgoingTrimDB: loudnessTrimDB(for: currentAnalysis),
            incomingTrimDB: loudnessTrimDB(for: next.analysis),
            outgoingAnalysis: currentAnalysis, incomingAnalysis: next.analysis,
            config: plannerConfig)
        let generation = resolveGeneration
        let stop = PrerenderCancel()
        stemPrerenderCancel = stop
        let cancellable: VocalStemProvider = { request in
            if stop.isCancelled { throw CancellationError() }
            return try provider(request)
        }
        stemPrerenderState = .running(signature)
        AutoMixDebugModel.shared.setPrerender(.rendering(Self.debugSignature(signature)))
        stemPrerenderTask = Task { [weak self] in
            // Separation is Metal work and rendering is a synchronous pull
            // loop; both belong off the main actor entirely.
            let segment = await Task.detached(priority: .utility) { () -> TransitionSegment? in
                try? TransitionSegmentRenderer.render(request, provider: cancellable)
            }.value
            guard let self, !Task.isCancelled, generation == self.resolveGeneration else { return }
            if let segment {
                // The engine rejects it if the seam moved underneath us or the
                // playhead is already past the splice, and plays the live
                // hand-over instead — this is a suggestion, not a command.
                self.engine.armTransitionSegment(segment)
                // The rejection is silent by design, so the only way to report
                // it is to ask afterwards. `hasArmedSegment` is the engine's
                // existing read-only hook, one queue hop, once per seam.
                AutoMixDebugModel.shared.setPrerender(
                    self.engine.hasArmedSegment
                        ? .armed(Self.debugSignature(signature))
                        : .refused("engine declined — seam moved or splice passed"))
            } else {
                AutoMixDebugModel.shared.setPrerender(.abandoned("render produced nothing"))
            }
            self.stemPrerenderTask = nil
            self.stemPrerenderState = .settled(signature)
        }
    }

    private func cancelStemPrerender() {
        stemPrerenderCancel?.cancel()
        stemPrerenderCancel = nil
        stemPrerenderTask?.cancel()
        stemPrerenderTask = nil
        stemPrerenderState = .idle
        AutoMixDebugModel.shared.setPrerender(.idle)
    }

    /// `Config.standard` with the one knob the user can see: the planner's
    /// loudness gate must measure the same thing the decks will play, so the
    /// compensation setting has to reach it.
    ///
    /// The debug panel's force override is applied here rather than at the one
    /// planning call, so the stem pre-render is built against the very config
    /// the plan was made under. Off — always, on iOS and for anyone who has not
    /// opened the panel — `plannerConfig` returns exactly what it always did.
    private var plannerConfig: TransitionPlanner.Config {
        var config = TransitionPlanner.Config.standard
        config.loudnessCompensation = loudnessCompensationEnabled
        return AutoMixDebugOverrides.plannerConfig(
            config, overrides: AutoMixDebugModel.shared.overrides)
    }

    /// Flip the debug panel's overrides and re-derive the hand-over that is
    /// already armed, so a toggle is heard at the *next* seam rather than the
    /// one after it — flipping and then replaying the same seam is the whole
    /// point of the switches.
    ///
    /// A plain re-plan is enough for the planner knobs: the engine only swaps a
    /// hand-over that has not started, so it can never cut audio. Turning the
    /// live path on needs more, because the engine has no un-arm call for a
    /// pre-rendered segment — the seam is torn down and re-armed instead, the
    /// same two calls a seek makes.
    func setOverrides(_ new: AutoMixOverrides) {
        let old = AutoMixDebugModel.shared.overrides
        AutoMixDebugModel.shared.writeOverrides(new)
        if new.needsReArm(comparedTo: old), transitionArmed {
            disarmTransition()
            armTransitionIfReady()
        } else {
            replanArmedTransition()
        }
    }

    /// Whether cross-track gain compensation is active right now. AutoMix off
    /// means no analyses are computed at all, so there is nothing to compensate
    /// with either.
    private var loudnessCompensationEnabled: Bool {
        #if os(iOS)
        return false
        #else
        return SettingsManager.shared.automixEnabled
            && SettingsManager.shared.loudnessCompensationEnabled
        #endif
    }

    /// The playback trim to load a track at, given whatever analysis is in hand.
    private func loudnessTrimDB(for analysis: TrackAnalysis?) -> Double {
        LoudnessCompensation.trimDB(for: analysis, enabled: loudnessCompensationEnabled)
    }

    /// Whether analysis results would ever be consumed: on iOS and with
    /// AutoMix off every plan is gapless, so decoding + analyzing the whole
    /// track would be pure waste.
    private var analysisWanted: Bool {
        #if os(iOS)
        return false
        #else
        return SettingsManager.shared.automixEnabled
        #endif
    }

    /// Sidecar-cached analysis, computing (and persisting) it on a miss.
    private func analysis(for key: AudioCache.Key, fileURL: URL) async -> TrackAnalysis? {
        guard analysisWanted else { return nil }
        if let cached = await AudioCache.shared.loadAnalysis(for: key) { return cached }
        let analyzed = await Task.detached(priority: .utility) {
            try? TrackAnalyzer.analyze(fileAt: fileURL)
        }.value
        if let analyzed {
            await AudioCache.shared.storeAnalysis(analyzed, for: key)
        }
        return analyzed
    }

    /// Analyze the track now playing once its complete file exists locally
    /// (cache hit, stream commit, or fallback download).
    private func ensureCurrentAnalysis(key: AudioCache.Key, fileURL: URL) {
        guard analysisWanted else { return }
        let generation = resolveGeneration
        Task { [weak self] in
            guard let self else { return }
            let result = await self.analysis(for: key, fileURL: fileURL)
            guard generation == self.resolveGeneration, let result else { return }
            self.currentAnalysis = result
            // The outgoing side of every candidate score just arrived; a pick
            // that was waiting on it can now be made. Harmless once the pick
            // is committed — `updateAutoMixPick` returns on the first guard.
            self.updateAutoMixPick()
            self.replanArmedTransition()
        }
    }

    /// The outgoing analysis landed after the hand-over was armed with a
    /// degraded plan — upgrade it in place. The engine only swaps the plan
    /// while the transition is still waiting, so audible audio is never cut.
    private func replanArmedTransition() {
        guard transitionArmed, let next = prefetchedNext else { return }
        let planned = makeTransitionPlan(for: next)
        engine.replaceTransitionPlan(planned)
        armedPlan = planned
        publishDebugPlan(planned, next: next)
    }

    /// The engine crossed the transition midpoint: the incoming deck is now
    /// the audible one, so the app's notion of "current track" flips here.
    private func adoptTransitionedTrack(on deck: Deck) {
        guard let next = pendingTransitionTrack else { return }
        scrobbleIfNeeded(completed: true)
        scrobbled = false
        consecutiveFailures = 0

        // Advance the queue pointers the same way advanceToNext would have.
        if isFMMode {
            if fmUpcoming.first?.id == next.id { fmUpcoming.removeFirst() }
        } else if playNextList.first?.id == next.id {
            playNextList.removeFirst()
        } else {
            // Advance sequentially like advanceToNext would; only fall back
            // to searching if the queue changed under us. A plain firstIndex
            // would jump back to an earlier copy of a duplicated track.
            var idx = currentIndex + 1
            if idx >= activeQueue.count { idx = 0 }
            if idx < activeQueue.count, activeQueue[idx].id == next.id {
                currentIndex = idx
            } else if let found = activeQueue.firstIndex(where: { $0.id == next.id }) {
                currentIndex = found
            }
        }

        currentTrack = next
        activeDeck = deck
        deckLoaded = true
        hasLocalFile = true
        isBuffering = false
        currentCacheKey = prefetchedNext?.key
        currentLocalURL = prefetchedNext?.localURL
        currentRemoteURL = nil
        currentAnalysis = prefetchedNext?.analysis
        servedQuality = prefetchedNext?.level
        unblockSource = prefetchedNext?.unblockSource
        isTrial = false
        isPlaying = true
        progress = engine.position(of: deck)
        duration = engine.duration(of: deck) ?? next.duration
        lyrics = nil
        currentLyricLRC = nil
        pendingTransitionTrack = nil
        prefetchedNext = nil
        // A hand-over is as much a "new track" as a manual start: without this
        // the committed flag survives into the next song, `autoMixPickPending`
        // never comes back up, and the mode silently degrades to list order
        // for every track that arrives via a transition (which is all of them).
        // `progress`/`duration`/`currentAnalysis` above are already this
        // track's, so the deadline the next tick reads is not stale.
        autoMixPickCommitted = false
        queueOrderSelector?.beginPick()
        // The song that was "next" is now "now"; `schedulePrefetch` (via
        // transitionCompleted) fills the group in again a moment later.
        AutoMixDebugModel.shared.clearNext()
        publishDebugNow()

        resolveGeneration += 1
        let generation = resolveGeneration
        NowPlayingManager.shared.updateMetadata(for: next, duration: duration)
        NowPlayingManager.shared.updateElapsed(progress, rate: 1)
        persistState()
        Task { await loadLyrics(for: next, generation: generation) }

        if isFMMode, fmUpcoming.count < 1 {
            Task {
                if let more = try? await NeteaseAPI.personalFM() {
                    fmUpcoming.append(contentsOf: more)
                    schedulePrefetch()
                }
            }
        }
    }

    private func loadLyrics(for track: Track, generation: Int) async {
        let response = try? await NeteaseAPI.lyric(id: track.id)
        guard generation == resolveGeneration else { return }
        lyrics = response.map(LyricsParser.parse)
        updateLyricsCursor(at: livePlaybackTime)
        currentLyricLRC = response?.lrc?.lyric
        persistCurrentLyricsSidecar()
    }

    /// Write the current track's `.lrc` next to its local file once both halves
    /// are known. The outgoing side of a seam is the one a `vocalExchange`
    /// reads, so the *playing* track needs its sidecar too — a prefetch-only
    /// write leaves the first track of every session wordless.
    ///
    /// Streaming-only playback has no file and writes nothing.
    private func persistCurrentLyricsSidecar(audio: URL? = nil) {
        guard let audio = audio ?? currentLocalURL, let lrc = currentLyricLRC else { return }
        Task.detached(priority: .utility) { LyricsSidecar.write(lrc, for: audio) }
    }

    // MARK: - AutoMix debug panel

    // Everything below only *reads* state this class already keeps, and writes
    // it into `AutoMixDebugModel`. Nothing here may change playback: the panel
    // is a mirror, and a mirror that moved the thing it reflects would make the
    // listening tests it exists for worthless.

    private static func debugSignature(_ signature: TransitionSegment.Signature) -> String {
        String(format: "out %.2fs · in %.2fs · overlap %.2fs",
               signature.outPoint, signature.inPoint, signature.overlapDuration)
    }

    /// A player-level phase. The engine's own `TransitionPhase` lives on its
    /// audio queue and is not reported, so this is what the *orchestrator*
    /// believes — which is also what the plan/pre-render groups are keyed to.
    private func debugPhaseLabel() -> String {
        guard deckLoaded else { return currentTrack == nil ? "idle" : "no source" }
        var phase = isBuffering ? "buffering" : (isPlaying ? "playing" : "paused")
        if transitionArmed { phase += " · handover armed" }
        return phase
    }

    private func publishDebugNow() {
        // One queue hop for both decks, and only while the panel is open — see
        // `PlaybackEngine.deckGains`. Reading them separately could straddle a
        // transition tick, which is the exact instant a stuck rate is about to
        // be explained away.
        let gains = engine.deckGains()
        func deck(_ which: Deck, _ snapshot: PlaybackEngine.DeckGainSnapshot)
            -> AutoMixDebugDeck {
            AutoMixDebugDeck(
                role: which == activeDeck
                    ? (transitionArmed ? "outgoing" : "playing")
                    : (transitionArmed ? "incoming" : "idle"),
                rate: snapshot.rate, trimDB: snapshot.trimDB, rideDB: snapshot.rideDB,
                ratePadDB: snapshot.ratePadDB, inTransition: snapshot.inTransition)
        }
        AutoMixDebugModel.shared.setNow(AutoMixDebugNow(
            title: currentTrack?.name,
            phase: debugPhaseLabel(),
            deck: activeDeck.rawValue.uppercased(),
            position: livePlaybackTime,
            duration: duration,
            trimDB: loudnessTrimDB(for: currentAnalysis),
            analyzed: currentAnalysis != nil,
            deckA: deck(.a, gains.a),
            deckB: deck(.b, gains.b)))
        publishDebugOrder()
    }

    /// How long a preview scoring pass is reused for while the pick is still
    /// pending. The table has to be *live* to be worth anything — the whole
    /// question is "what is it weighing right now" — but a pass costs one
    /// `TransitionPlanner.plan` per candidate, which is not a thing to run
    /// five times a second. Two seconds is faster than a listener can read a
    /// row and slow enough to be free.
    private static let debugOrderPreviewInterval: TimeInterval = 2

    private var lastDebugOrderPreview: Date = .distantPast

    /// The queue-order group. Only ever called from `publishDebugNow`, which
    /// only the open panel calls — so the preview pass below cannot cost a
    /// closed window anything.
    private func publishDebugOrder() {
        guard let selector = queueOrderSelector else {
            AutoMixDebugModel.shared.setOrder(AutoMixDebugOrder(mode: queueOrder.rawValue))
            return
        }
        let remaining = autoMixRemaining()
        let pool = selector.pool(remaining: remaining)
        // While the pick is pending, re-score for display. This does not age
        // anything — `noteRound` is the only thing that moves a counter — so
        // previewing is free of consequence, and after the commit the table is
        // the real one, frozen.
        if autoMixPickPending, currentAnalysis != nil,
           Date().timeIntervalSince(lastDebugOrderPreview) >= Self.debugOrderPreviewInterval {
            lastDebugOrderPreview = Date()
            // A preview pass is one full rank of the pool — the same work the
            // real pick does, and measured under the same tripwire. It stays on
            // the main actor because that is where `lastPick` lives and because
            // one rank measures 0.9 ms in release (13.8 ms in debug) at a
            // 156-track pool; the throttle above is what keeps it there.
            let start = ContinuousClock.now
            _ = selector.pick(
                outgoing: currentTrack, outgoingAnalysis: currentAnalysis, pool: pool,
                plannerConfig: plannerConfig,
                outgoingLyricLineEnds: currentLocalURL
                    .map { Audition.Lyrics.lineEnds(for: $0) } ?? [])
            Self.noteIfSlow("debug-preview", (ContinuousClock.now - start).milliseconds,
                            detail: "pool=\(pool.count)")
        }
        let candidates = selector.lastPick.enumerated().map { index, candidate in
            AutoMixDebugCandidate(
                id: candidate.track.id, title: candidate.track.name,
                tier: candidate.score.tier.label,
                tempo: candidate.score.tempoAffinity, key: candidate.score.keyAffinity,
                style: candidate.score.styleAffinity, energy: candidate.score.energyContinuity,
                aging: candidate.score.aging, samePenalty: candidate.score.sameArtistPenalty,
                future: candidate.score.futureRichness,
                total: candidate.score.total, chosen: index == 0)
        }
        let state: String
        if isTrial {
            state = "stood down — trial fragment (never cached, no analysis possible)"
        } else if !playNextList.isEmpty {
            state = "stood down — a manual “play next” is sovereign"
        } else if autoMixPickCommitted {
            state = "decided"
        } else if currentAnalysis == nil {
            state = "waiting for the playing track's own analysis"
        } else {
            state = "choosing"
        }
        AutoMixDebugModel.shared.setOrder(AutoMixDebugOrder(
            mode: queueOrder.rawValue, state: state,
            poolSize: remaining.count,
            analyzed: pool.count,
            rounds: selector.rounds, downloads: selector.downloadsThisPick,
            downloadBudget: selector.config.maxDownloadsPerPick,
            lookahead: selector.lookahead.map {
                "\($0.track.name) — \($0.score.tier.label)"
            },
            deadline: duration > 0 ? autoMixDeadline : nil,
            candidates: candidates))
    }

    private func publishDebugPlan(_ planned: PlannedTransition, next: PrefetchedNext) {
        AutoMixDebugModel.shared.setPlan(AutoMixDebugPlan(
            planned: planned, outgoing: currentAnalysis, incoming: next.analysis))
        // The sidecar may have landed since the prefetch reported; a re-plan is
        // the natural moment to re-read it, and it is one `stat`.
        AutoMixDebugModel.shared.setNextAnalysis(next.analysis, localURL: next.localURL)
        // A replay is waiting for exactly this: the seam it asked for, planned
        // with both analyses in hand.
        serviceSeamReplayIfPending()
    }

    /// The seam just became audible: freeze what was armed next to what the
    /// engine says it actually ran, so a listener who heard something odd can
    /// look afterwards instead of guessing.
    private func recordDebugSeam(_ outcome: TransitionOutcome) {
        let planned = armedPlan.map {
            AutoMixDebugPlan(planned: $0, outgoing: currentAnalysis,
                             incoming: prefetchedNext?.analysis)
        }
        AutoMixDebugModel.shared.recordSeam(AutoMixDebugSeam(
            from: currentTrack?.name,
            to: pendingTransitionTrack?.name,
            // Kept so the pair can be queued up and heard again; both are
            // cached files by now, so a replay is a queue rebuild and a seek.
            outgoingTrack: currentTrack,
            incomingTrack: pendingTransitionTrack,
            gesture: armedPlan?.style.stemTechnique?.label,
            overrides: AutoMixDebugModel.shared.overrides.badges,
            configFingerprint: AutoMixFeedbackLog.configFingerprint(plannerConfig),
            planned: planned,
            path: outcome.path.rawValue,
            executedKind: AutoMixDebugFormat.planKind(outcome.plan),
            executedOutPoint: outcome.plan.outPoint,
            executedOverlap: AutoMixDebugFormat.overlap(outcome.plan),
            fallback: AutoMixDebugFormat.fallback(planned: planned, executed: outcome.plan),
            prerender: AutoMixDebugModel.shared.currentPrerenderLabel))
    }

    // MARK: - Debug panel: jump, replay, mark

    /// Why the panel's jump button is unavailable, or nil when it is not.
    var seamJumpBlocker: String? {
        guard transitionArmed, let planned = armedPlan else { return "nothing armed" }
        guard let outPoint = planned.plan.outPoint else {
            return "gapless — the seam is the end of the track"
        }
        guard outPoint > progress else { return "the out point is already behind us" }
        return nil
    }

    /// The lead this seam needs, and why — the same computation the button
    /// performs, exposed so the panel can show it before anyone presses.
    func seamJumpPlan() -> AutoMixSeamJump.Result? {
        guard seamJumpBlocker == nil, let planned = armedPlan,
              let outPoint = planned.plan.outPoint else { return nil }
        var inputs = AutoMixSeamJump.Inputs(outPoint: outPoint)
        if case .beatMatched(let p) = planned.plan {
            inputs.isBeatMatched = true
            inputs.rampLeadSeconds = p.rampLeadSeconds
        }
        // The pad the *outgoing* deck will actually use, straight off the deck
        // that is carrying the track — it is sized from that track's peak, so
        // there is no useful constant to substitute.
        inputs.padDB = engine.deckGains(of: activeDeck).padCeilingDB
        inputs.needsStemPrerender = planned.style.stemTechnique != nil
            && StemSeparation.isAvailable
            && !AutoMixDebugModel.shared.overrides.forceLivePath
        inputs.segmentArmed = engine.hasArmedSegment
        inputs.prerenderLead = Self.stemPrerenderLead
        inputs.prerenderHandoff = TransitionSegmentRenderer.handoff
        return AutoMixSeamJump.compute(inputs)
    }

    /// Seek to the latest position that still leaves every stage of the
    /// pipeline room to do its work. Goes through the ordinary `seek`, which
    /// re-validates the armed hand-over against the new playhead — a jump must
    /// not be a second, private path into the transition machinery.
    func jumpToArmedSeam() {
        guard let jump = seamJumpPlan() else { return }
        seek(to: jump.target)
    }

    /// Set while a replay is waiting for its rebuilt queue to arm a hand-over.
    /// One-shot: cleared by the jump it triggers, and by any track change.
    private var pendingSeamReplay = false

    /// Why the panel cannot replay this seam, or nil when it can.
    func seamReplayBlocker(_ seam: AutoMixDebugSeam) -> String? {
        guard seam.outgoingTrack != nil, seam.incomingTrack != nil else {
            return "this seam was recorded without its tracks"
        }
        return nil
    }

    /// Queue the recorded pair again and jump to just before the seam, so the
    /// same hand-over runs a second time.
    ///
    /// The plan is **re-derived, not replayed**: both analyses are cached, so
    /// the planner should reach the same decision, and the panel badges the
    /// difference if it does not. Replaying a frozen plan would hide exactly
    /// the thing an A/B is trying to see — that a toggle changed the decision.
    ///
    /// The queue is rebuilt as an ad-hoc two-track list, which replaces
    /// whatever was playing (personal FM included). That is the honest cost of
    /// the feature and the panel says so.
    func replaySeam(_ seam: AutoMixDebugSeam) {
        guard seamReplayBlocker(seam) == nil,
              let outgoing = seam.outgoingTrack, let incoming = seam.incomingTrack
        else { return }
        AutoMixDebugModel.shared.setReplayDiff(nil)
        replayTarget = seam
        play(tracks: [outgoing, incoming], source: .none, startAt: outgoing)
        // Set after `play`, which runs `startPlaying` and clears it.
        pendingSeamReplay = true
    }

    /// The seam a pending replay is trying to reproduce, for the diff badge.
    private var replayTarget: AutoMixDebugSeam?

    /// Called from `publishDebugPlan`: a replay waits for the *upgraded* plan,
    /// not the first degraded one, because the outgoing analysis lands a beat
    /// after playback starts and the seam is only real once it has.
    private func serviceSeamReplayIfPending() {
        guard pendingSeamReplay, currentAnalysis != nil, seamJumpBlocker == nil
        else { return }
        pendingSeamReplay = false
        if let target = replayTarget?.planned, let planned = armedPlan {
            AutoMixDebugModel.shared.setReplayDiff(
                AutoMixDebugFormat.fallback(planned: target, executed: planned.plan))
        }
        replayTarget = nil
        // Off this turn of the loop: we are inside `armTransitionIfReady`, and
        // `seek` disarms and re-arms — doing that to the frame we are standing
        // in would work, but only by accident.
        Task { @MainActor [weak self] in
            guard let self, let jump = self.seamJumpPlan() else { return }
            self.seek(to: jump.target)
        }
    }

    /// Append a listening verdict to the feedback corpus. `seam` nil marks the
    /// hand-over that is armed right now, which has no executed side yet.
    @discardableResult
    func markSeam(verdict: AutoMixFeedbackEntry.Verdict, note: String?,
                  seam: AutoMixDebugSeam?) -> Bool {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let armed = armedPlan.map {
            AutoMixDebugPlan(planned: $0, outgoing: currentAnalysis,
                             incoming: prefetchedNext?.analysis)
        }
        let entry = AutoMixFeedbackEntry(
            at: seam?.at ?? Date(),
            verdict: verdict,
            note: (trimmed?.isEmpty ?? true) ? nil : trimmed,
            outgoing: (seam?.outgoingTrack ?? currentTrack)
                .map { .init(id: $0.id, title: $0.name) },
            incoming: (seam?.incomingTrack ?? pendingTransitionTrack)
                .map { .init(id: $0.id, title: $0.name) },
            planned: (seam?.planned ?? armed).map(AutoMixFeedbackEntry.PlanRef.init),
            executed: seam.map {
                .init(kind: $0.executedKind, outPoint: $0.executedOutPoint,
                      overlap: $0.executedOverlap)
            },
            gesture: seam?.gesture ?? armedPlan?.style.stemTechnique?.label,
            path: seam?.path,
            overrides: seam?.overrides ?? AutoMixDebugModel.shared.overrides.badges,
            config: seam.map { $0.configFingerprint.isEmpty
                ? AutoMixFeedbackLog.configFingerprint(plannerConfig)
                : $0.configFingerprint }
                ?? AutoMixFeedbackLog.configFingerprint(plannerConfig))
        guard AutoMixFeedbackLog.append(entry) else { return false }
        AutoMixDebugModel.shared.countMark()
        return true
    }

    // MARK: - Scrobble

    /// Tell the server the track started, once per track. Called from the
    /// point playback actually begins — the cache-hit path and the streaming
    /// path both reach it, and `startPlaying` clears the flag.
    private func scrobbleStartIfNeeded(_ track: Track) {
        guard !startScrobbled else { return }
        startScrobbled = true
        let tid = track.id
        let sid = source.sourceID
        Task.detached { await NeteaseAPI.scrobbleStart(trackID: tid, sourceID: sid) }
    }

    private func scrobbleIfNeeded(completed: Bool) {
        guard let track = currentTrack, !scrobbled, progress > 1 else { return }
        scrobbled = true
        let seconds = completed ? Int(duration) : Int(progress)
        let sourceID = source.sourceID
        Task.detached {
            await NeteaseAPI.scrobbleFinish(trackID: track.id, sourceID: sourceID, seconds: seconds)
        }
    }

    // MARK: - Shuffle helpers

    private func reshuffle(keeping first: Track) {
        var rest = queue.filter { $0.id != first.id }
        rest.shuffle()
        shuffledQueue = [first] + rest
    }

    /// The AutoMix order's equivalent: the same "current track first, the rest
    /// behind it" contract shuffle has, except the rest keeps list order —
    /// nothing is decided yet, and predev §2.1 forbids pretending otherwise.
    private func reorderForAutoMix(keeping first: Track) {
        autoMixQueue = [first] + queue.filter { $0.id != first.id }
    }

    // MARK: - AutoMix queue order (predev §2.2 / §2.4)

    /// Nil whenever the mode is off — which is the whole of predev §5.3's
    /// regression contract. A player in `.listed` or `.shuffled` allocates no
    /// selector, scores nothing and issues no candidate request.
    private var queueOrderSelector: QueueOrderSelector?
    /// The pick for the track now playing has been made (or deliberately
    /// declined). Cleared by `startPlaying`, so every track gets exactly one
    /// decision round.
    private var autoMixPickCommitted = false

    /// How long before the end of the track the pick is made even if
    /// candidates are still downloading.
    ///
    /// The winner does not go straight to the engine: it still has to be
    /// re-resolved, downloaded at *playback* quality and re-analyzed by the
    /// ordinary prefetch path (a lossy file's beat grid may not be aligned to
    /// the real one — predev §2.2), and a stem hand-over then wants
    /// `stemPrerenderLead` = 60 s on top.
    ///
    /// 90 s was sized as 30 for the first half and 60 for the second. The first
    /// half measured 40 s and more in the field — a lossless transfer on a
    /// domestic line plus an analyzer pass — so the pre-render was routinely
    /// handed under 50 s and the stem gesture dropped to a whole-mix crossfade
    /// without anyone being told. 120 s is the same arithmetic with the
    /// measured number in it. The fraction floor keeps a short track from
    /// deciding before it has played at all.
    ///
    /// This is the *worst* case, not the common one: only a deadline-committed
    /// pick waits this long. A pick that satisfies, exhausts the queue or spends
    /// its download budget commits as soon as it does, which on a warm pool is
    /// within seconds of the track starting.
    private static let autoMixDecisionLead: TimeInterval = 120

    private var autoMixDeadline: TimeInterval {
        max(duration - Self.autoMixDecisionLead, duration * 0.35)
    }

    /// The mode is on and owes an answer — so the prefetch pipeline must wait
    /// rather than commit to whatever the list happens to say next.
    private var autoMixPickPending: Bool {
        queueOrderSelector != nil && queueOrder == .autoMix
            && !autoMixPickCommitted && !isFMMode && playNextList.isEmpty
            // A trial fragment is never cached, so it never gets an analysis
            // and never reaches its metadata-length deadline (the fragment
            // ends first) — a pick would pend forever while the escalation
            // opens a pointless round per fragment. The mode stands down
            // exactly like FM: nothing to plan with, nothing to hold up.
            && !isTrial
    }

    private func syncQueueOrderSelector() {
        guard queueOrder == .autoMix, autoMixOrderAvailable else {
            queueOrderSelector = nil
            return
        }
        guard queueOrderSelector == nil else {
            queueOrderSelector?.reset()
            return
        }
        let selector = QueueOrderSelector()
        selector.onCandidateReady = { [weak self] in
            self?.updateAutoMixPick()
            // The pool just grew, so the provisional chain past the decided
            // next may well be different now. Redoing it is microseconds.
            self?.refreshAutoMixLookahead()
        }
        queueOrderSelector = selector
    }

    /// Everything still ahead of the playhead in the working list.
    private func autoMixRemaining() -> [Track] {
        guard currentIndex >= 0, currentIndex + 1 < activeQueue.count else { return [] }
        return Array(activeQueue[(currentIndex + 1)...])
    }

    /// Polled from the progress tick while the mode owes a decision: top the
    /// candidate pool up, and pick as soon as there is nothing left to wait
    /// for — or when the deadline arrives, whichever comes first.
    ///
    /// Costs one optional test per tick with the mode off.
    private func updateAutoMixPick() {
        guard autoMixPickPending, let selector = queueOrderSelector else { return }
        let remaining = autoMixRemaining()
        // Nothing to choose between: let the ordinary pipeline have the track
        // the list already points at.
        guard remaining.count > 1 else {
            return commitAutoMixPick(nil, pool: [], reason: "trivial-queue")
        }

        let atDeadline = duration > 0 && progress >= autoMixDeadline
        // Scoring against a missing outgoing analysis is not scoring: every
        // candidate comes back `.gapless`, so "is this one good enough" has no
        // answer and the escalation would have nothing to steer by. Until the
        // playing track's own analysis lands, acquisition is limited to the
        // free half — the disk scan — and the deadline still takes over.
        guard currentAnalysis != nil || atDeadline else {
            selector.acquire(remaining: remaining, mayDownload: false)
            return
        }

        let pool = selector.pool(remaining: remaining)
        // The real decision stays on the main actor: one rank measures 0.9 ms
        // in release and 13.8 ms in debug at a 156-track pool, it happens once
        // per landing candidate rather than nine times, and the pick is the one
        // thing here that is not provisional. The tripwire says so if that
        // stops being true.
        let pickStart = ContinuousClock.now
        let winner = selector.pick(
            outgoing: currentTrack, outgoingAnalysis: currentAnalysis, pool: pool,
            plannerConfig: plannerConfig,
            outgoingLyricLineEnds: currentLocalURL
                .map { Audition.Lyrics.lineEnds(for: $0) } ?? [])
        Self.noteIfSlow("pick", (ContinuousClock.now - pickStart).milliseconds,
                        detail: "pool=\(pool.count)")
        // Good enough is good enough: the tier is the dominant term, so a
        // further round can only buy a *higher* tier or a second-order
        // reshuffle inside this one — not worth another download and another
        // minute of waiting.
        if atDeadline || selector.lastPickSatisfies {
            return commitAutoMixPick(winner, pool: pool,
                                     reason: atDeadline ? "deadline" : "satisfied")
        }
        // Nothing satisfies yet: open the next round, unless the queue is spent
        // or this pick has spent its budget — in either case the best analyzed
        // candidate is the answer, and a nil one honestly leaves the list order
        // alone. The budget stop differs only in what it means: the queue still
        // has material, and the next pick escalates into it from the pool this
        // one just enriched.
        switch selector.acquire(remaining: remaining, mayDownload: autoMixMayDownload) {
        case .exhausted: commitAutoMixPick(winner, pool: pool, reason: "exhausted")
        case .spent: commitAutoMixPick(winner, pool: pool, reason: "budget")
        case .acquiring, .deferred: break
        }
    }

    /// Whether the escalation may open a transfer right now.
    ///
    /// The politeness rule (predev §2.2's budget of one): candidate downloads
    /// are background work and never compete with audio that is about to play,
    /// or is playing. `prefetchTask` is the playback-quality fetch of the
    /// *chosen* next track — while the pick is pending `schedulePrefetch` has
    /// already stood it down, so this is nil then by construction — and
    /// `currentLocalURL` is nil exactly while the current track is still
    /// streaming into the cache (not `hasLocalFile`, which describes the
    /// deck's *source* and stays false for a streamed track even after its
    /// download completes — that read kept the escalation deferred for the
    /// whole first song of a fresh playlist). Both resume the escalation on
    /// their own: the progress tick calls back in every second.
    private var autoMixMayDownload: Bool {
        prefetchTask == nil && currentLocalURL != nil
    }

    /// Freeze the decision for this track and hand the pipeline the result.
    ///
    /// **This is the one change to the advance path.** Rather than teach
    /// `advanceToNext` a second way to find "next", the winner is spliced to
    /// `currentIndex + 1` — so `currentIndex + 1` is still the answer, and
    /// every index-based path downstream is untouched. A nil winner (nothing
    /// analyzed by the deadline) leaves the list exactly as it was: the mode
    /// never holds up a hand-over waiting for a download.
    private func commitAutoMixPick(_ winner: Track?, pool: [Track],
                                   reason: String) {
        autoMixPickCommitted = true
        let tier = queueOrderSelector?.lastPick.first?.score.tier.label ?? "-"
        PlaybackJournal.note(
            "order commit reason=\(reason) winner=\(winner?.id.description ?? "none") "
            + "tier=\(tier) analyzed=\(pool.count) "
            + "rounds=\(queueOrderSelector?.rounds ?? 0) "
            + "downloads=\(queueOrderSelector?.downloadsThisPick ?? 0)")
        if let winner {
            queueOrderSelector?.noteRound(chosen: winner, pool: pool)
            spliceAutoMixPlan([winner])
        }
        // The chain's head just changed: this is the one moment it is worth
        // being right, so it jumps the throttle.
        refreshAutoMixLookahead(force: true)
        schedulePrefetch()
    }

    /// Move `tracks` to sit at `currentIndex + 1, + 2, …` in the working list,
    /// in the order given, leaving everything else in the order the user gave
    /// us.
    ///
    /// One track is the decided next — firm. The rest is the provisional chain,
    /// and it is shown rather than promised: the pick at each of those seams is
    /// still made fresh at its own decision point, and a chain step that turns
    /// out wrong is simply re-spliced then. Materializing it into the list
    /// (rather than teaching `upcomingTracks` a second source of truth) is the
    /// same trick the decided next already uses, so `currentIndex` stays the
    /// only cursor there is.
    ///
    /// **One assignment, or none.** `autoMixQueue` is `@Published` and the
    /// queue view is a list of a few hundred rows, so every mutation costs a
    /// full SwiftUI diff of the whole list. The first version of this moved the
    /// tracks one at a time — nine publishes and nine diffs per refresh, on
    /// every candidate that landed. The reordered array is now built whole and
    /// assigned once, and not assigned at all when the order is already what it
    /// should be, which is the common case after the first refresh.
    private func spliceAutoMixPlan(_ tracks: [Track]) {
        guard let reordered = Self.queueSplicingPlan(
            autoMixQueue, at: currentIndex + 1, plan: tracks) else { return }
        autoMixQueue = reordered
    }

    /// The reordered queue, or **nil when it would change nothing** — which is
    /// the common case once the chain has settled, and the signal the caller
    /// uses to skip the publish entirely.
    ///
    /// Pure, so the property that matters (this is a permutation of the input
    /// that moves the plan to the front of the tail and disturbs nothing else)
    /// is assertable without a player.
    nonisolated static func queueSplicingPlan(
        _ queue: [Track], at target: Int, plan: [Track]
    ) -> [Track]? {
        guard target >= 0, target <= queue.count else { return nil }
        let ahead = queue[target...]
        let aheadIDs = Set(ahead.map(\.id))
        var planned: [Track] = []
        var placed: Set<Int> = []
        // Only tracks that are actually still ahead of the playhead, each once.
        for track in plan where aheadIDs.contains(track.id) && !placed.contains(track.id) {
            placed.insert(track.id)
            planned.append(track)
        }
        guard !planned.isEmpty else { return nil }
        let reordered = Array(queue[..<target]) + planned
            + ahead.filter { !placed.contains($0.id) }
        // Compare identities, not whole tracks: a `Track` carries nested arrays
        // and this runs on every refresh.
        guard reordered.map(\.id) != queue.map(\.id) else { return nil }
        return reordered
    }

    /// How often the provisional chain may be recomputed off the back of a
    /// landing analysis.
    ///
    /// A commit always recomputes — that is the moment the chain's head
    /// changes and the moment it is worth being right. In between, candidates
    /// land every few seconds during an escalation, and a pool one track richer
    /// does not meaningfully change an eight-step preview. So the pool-growth
    /// trigger is throttled and the work is skipped rather than queued.
    static let lookaheadRefreshInterval: TimeInterval = 5

    /// The throttle rule, in one place: a commit always goes, a landing
    /// analysis waits its turn, and only one computation is ever in flight.
    nonisolated static func lookaheadRefreshAllowed(
        force: Bool, computing: Bool, sinceLast: TimeInterval
    ) -> Bool {
        force || (!computing && sinceLast >= lookaheadRefreshInterval)
    }

    private var lastLookaheadRefresh: Date = .distantPast
    /// A chain computation is in flight; a second one would only race it.
    private var lookaheadComputing = false
    /// Bumped whenever the chain's premise changes, so an answer computed
    /// against a queue that has since moved on is dropped rather than shown.
    private var lookaheadGeneration = 0

    /// Redo the provisional chain and lay it into the working list.
    ///
    /// Called on every commit, whenever a candidate analysis lands (the pool
    /// grew) and when the queue is edited.
    ///
    /// The computation itself runs **off the main actor**. Measured at a
    /// 156-track pool it is 5.6 ms in release and 110 ms in debug, and it grows
    /// linearly with the pool — which grew from the 4-track window this feature
    /// shipped with to 200+ as the cache warmed. Main-actor work of that size,
    /// arriving every time a download lands, is a stutter; it is what made the
    /// app appear to hang after a queue action.
    private func refreshAutoMixLookahead(force: Bool = false) {
        guard let selector = queueOrderSelector, queueOrder == .autoMix else { return }
        // The chain hangs off the decided next. While the pick is still
        // pending there is nothing to hang it off, and showing a chain from a
        // head that is about to change would be worse than showing none.
        guard !autoMixPickPending, currentIndex >= 0,
              currentIndex + 1 < autoMixQueue.count else {
            lookaheadGeneration += 1
            return selector.clearLookahead()
        }
        guard selector.config.lookaheadDepth > 0 else { return selector.clearLookahead() }
        let now = Date()
        // A commit forces; a landing analysis waits its turn. Either way only
        // one computation is ever in flight — a forced one supersedes whatever
        // is running by bumping the generation below, and the superseded task
        // drops its answer without touching the flag.
        guard Self.lookaheadRefreshAllowed(
            force: force, computing: lookaheadComputing,
            sinceLast: now.timeIntervalSince(lastLookaheadRefresh)) else { return }

        let head = autoMixQueue[currentIndex + 1]
        let rest = Array(autoMixQueue[(currentIndex + 2)...])
        lastLookaheadRefresh = now
        lookaheadComputing = true
        lookaheadGeneration += 1
        let generation = lookaheadGeneration
        let depth = selector.config.lookaheadDepth
        let input = selector.chainInput(head: head, remaining: rest,
                                        plannerConfig: plannerConfig)
        Task { [weak self] in
            let start = ContinuousClock.now
            let results = await Task.detached(priority: .utility) {
                QueueOrderSelector.chain(input, depth: depth)
            }.value
            let elapsed = (ContinuousClock.now - start).milliseconds
            guard let self else { return }
            // A commit, a queue edit or a track change happened while this was
            // running: its premise is gone, and a provisional chain is never
            // worth showing against the wrong head. The flag stays set — it
            // belongs to whichever computation superseded this one.
            guard generation == self.lookaheadGeneration else { return }
            self.lookaheadComputing = false
            guard self.currentIndex >= 0,
                  self.currentIndex + 1 < self.autoMixQueue.count,
                  self.autoMixQueue[self.currentIndex + 1].id == input.headID else { return }
            let current = Array(self.autoMixQueue[(self.currentIndex + 2)...])
            self.queueOrderSelector?.applyLookahead(results, remaining: current)
            let chain = self.queueOrderSelector?.lookahead.map(\.track) ?? []
            self.spliceAutoMixPlan([head] + chain)
            Self.noteIfSlow("lookahead", elapsed,
                            detail: "pool=\(input.poolIDs.count) depth=\(depth) "
                                + "steps=\(chain.count)")
        }
    }

    /// The permanent tripwire on the queue-order arithmetic.
    ///
    /// Everything this mode computes was designed when the pool was four tracks
    /// and described in the predev as "microseconds". The pool is now whatever
    /// the cache has warmed to, and the cost is linear in it — so the honest
    /// thing is not to assert the cost is small but to say so out loud the
    /// moment it is not. 50 ms is three frames.
    private static let slowWorkThresholdMS: Double = 50

    private static func noteIfSlow(_ what: String, _ ms: Double, detail: String) {
        guard ms >= slowWorkThresholdMS else { return }
        PlaybackJournal.note(String(format: "order SLOW %@ %.0fms %@", what, ms, detail))
    }

    // MARK: - Persistence

    private static let recentContextsLimit = 6

    private func recordRecent(_ context: PlayContext) {
        recentContexts.removeAll { $0 == context }
        recentContexts.insert(context, at: 0)
        if recentContexts.count > Self.recentContextsLimit {
            recentContexts.removeLast(recentContexts.count - Self.recentContextsLimit)
        }
    }

    /// Reloads a place from the recents list and starts playing it again.
    func play(context: PlayContext) {
        // Personal FM is a stream, not a fixed list — restart it in place.
        guard context.kind != .fm else { return startFM() }
        Task {
            do {
                guard let resolved = try await resolve(context) else { return }
                play(tracks: resolved.tracks, source: resolved.source, context: context)
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private func resolve(_ context: PlayContext) async throws -> (tracks: [Track], source: PlaySource)? {
        switch context.kind {
        case .fm:
            return nil
        case .album:
            return (try await NeteaseAPI.album(id: context.id).songs, .album(context.id))
        case .artist:
            return (try await NeteaseAPI.artist(id: context.id).hotSongs, .artist(context.id))
        case .daily:
            return (try await NeteaseAPI.dailyRecommendSongs(), .daily)
        case .cloud:
            let songs = try await NeteaseAPI.cloudSongs().data?.compactMap(\.simpleSong) ?? []
            return (songs, .cloud)
        case .recents:
            guard let uid = AccountStore.shared.profile?.userId else { return nil }
            return (try await NeteaseAPI.playRecords(uid: uid, week: false).map(\.song), .none)
        case .heartbeat:
            // Regenerated from a fresh seed, the same way the Home card does it.
            guard let liked = AccountStore.shared.likedSongsPlaylist,
                  let seed = AccountStore.shared.likedTrackIDs.randomElement() else { return nil }
            let tracks = try await NeteaseAPI.intelligenceList(songID: seed, playlistID: liked.id)
            return (tracks, .playlist(liked.id))
        case .playlist:
            let response = try await NeteaseAPI.playlistDetail(id: context.id)
            var tracks = response.playlist.tracks
            // /v6/playlist/detail only carries the first page of tracks.
            let remaining = response.playlist.trackIds.map(\.id).dropFirst(tracks.count)
            for chunk in stride(from: 0, to: remaining.count, by: 500)
                .map({ Array(remaining.dropFirst($0).prefix(500)) }) {
                guard let more = try? await NeteaseAPI.songDetails(ids: chunk) else { break }
                tracks += more.songs
            }
            return (tracks, .playlist(context.id))
        }
    }

    struct PersistedState: Codable {
        var queue: [Track]
        var currentID: Int?
        var repeatMode: String
        /// The pre-`QueueOrder` two-state flag. Still written, so a build
        /// without the queue-order mode reads a sane session back; still read,
        /// as the migration source for a state file written before
        /// `queueOrder` existed.
        var shuffle: Bool
        /// Optional so state files written before recents existed still decode.
        var recentContexts: [PlayContext]?
        /// Optional for the same reason — absent means "migrate from
        /// `shuffle`". See `QueueOrder.init(migratingShuffle:)`.
        var queueOrder: String?
    }

    private func persistState() {
        let state = PersistedState(
            queue: Array(queue.prefix(1000)),
            currentID: currentTrack?.id,
            repeatMode: repeatMode.rawValue,
            shuffle: shuffleEnabled,
            recentContexts: recentContexts,
            queueOrder: queueOrder.rawValue
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        let url = Self.stateFileURL
        Task.detached {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func restoreState() {
        guard let data = try? Data(contentsOf: Self.stateFileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        // Recents outlive the queue: restore them before bailing out on an
        // empty queue, or the next played track persists an empty list over
        // them and the Dock menu loses its history for good.
        recentContexts = Array((state.recentContexts ?? []).prefix(Self.recentContextsLimit))
        guard !state.queue.isEmpty else { return }
        queue = state.queue
        queueOrder = PlayerService.restoredQueueOrder(state)
        syncQueueOrderSelector()
        switch queueOrder {
        case .listed: break
        case .shuffled: shuffledQueue = queue.shuffled()
        // No pick has been made for a session that has not started playing,
        // so the working list is the plain queue — which is what the mode
        // shows anyway until the first decision lands.
        case .autoMix: autoMixQueue = queue
        }
        if let id = state.currentID,
           let idx = activeQueue.firstIndex(where: { $0.id == id }) {
            currentIndex = idx
            currentTrack = activeQueue[idx]
            duration = activeQueue[idx].duration
            NowPlayingManager.shared.updateMetadata(for: activeQueue[idx], duration: duration)
            Task {
                await loadLyrics(for: activeQueue[idx], generation: resolveGeneration)
            }
        }
    }

    /// The queue order a persisted session restores to, migrating a state file
    /// written before the mode existed. Static and pure so the migration is
    /// testable without a player.
    nonisolated static func restoredQueueOrder(_ state: PersistedState) -> QueueOrder {
        state.queueOrder.flatMap(QueueOrder.init(rawValue:))
            ?? QueueOrder(migratingShuffle: state.shuffle)
    }

    private static var stateFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kumone", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("player-state.json")
    }
}
