#if os(iOS)
import Combine
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
    let sleepTimer = SleepTimer()
    /// Passthrough to the clock so existing `progress` reads/writes keep working.
    var progress: TimeInterval {
        get { clock.progress }
        set { clock.progress = newValue }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "player.repeat") }
    }

    @Published private(set) var shuffleEnabled = false
    @Published var volume: Float = 1 {
        didSet {
            engine.volume = volume
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

    /// The list the player is walking through (shuffled or ordered).
    var activeQueue: [Track] { shuffleEnabled ? shuffledQueue : queue }

    var upcomingTracks: [Track] {
        guard !activeQueue.isEmpty, currentIndex >= 0 else { return playNextList }
        let rest = activeQueue.suffix(from: min(currentIndex + 1, activeQueue.count))
        return playNextList + Array(rest.prefix(200))
    }

    var hasCurrentTrack: Bool { currentTrack != nil }

    // MARK: - Engine

    private let engine = AVPlayer()

    /// Live playback position straight from the player, for smooth per-frame
    /// karaoke highlighting (the published `progress` is intentionally coarse).
    var livePlaybackTime: TimeInterval {
        let t = engine.currentTime().seconds
        return t.isFinite ? t : progress
    }
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var audioResourceLoader: CachingAudioResourceLoader?
    private var pendingAudioResourceLoader: CachingAudioResourceLoader?
    private var audioCacheLease: UUID?
    private var statusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var resolveGeneration = 0
    private var consecutiveFailures = 0
    private var attemptedUnblockSources: Set<AudioSourceID> = []
    private var currentUnblockSourceID: AudioSourceID?
    private var scrobbled = false
    private var startScrobbled = false

    // MARK: - Offline playback (downloads)

    /// The song that could not play because it is not on this device.
    @Published var offlineIssue: OfflinePlaybackIssue?
    /// Held while the player item reads a downloaded file, so the download
    /// cannot be deleted from under it.
    private var offlinePlaybackLease: OfflinePlaybackLease?
    private var offlineScan: Task<Void, Never>?
    private var offlineScanID = UUID()
    private var networkState = DownloadNetworkState.unknown
    private var networkObservation: AnyCancellable?
    private var offlineActivatedScope: String?
    /// Set by an automatic advance and consumed by `startPlaying`: a song that
    /// turns out to be missing offline is skipped rather than reported.
    private var pendingAutoAdvance = false
    private var currentWasAdvanced = false

    private enum ResolvedURLLoadResult {
        case loaded
        case superseded
    }

    private init() {
        engine.actionAtItemEnd = .pause
        sleepTimer.onDeadlineReached = { [weak self] in
            self?.pause()
        }
        volume = UserDefaults.standard.object(forKey: "player.volume") as? Float ?? 0.8
        engine.volume = volume
        repeatMode = UserDefaults.standard.string(forKey: "player.repeat")
            .flatMap(RepeatMode.init) ?? .off

        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to activate audio session: \(error)")
        }

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

        timeObserver = engine.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                let seconds = time.seconds
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
                    NowPlayingManager.shared.updateElapsed(seconds, rate: self.isPlaying ? 1 : 0)
                }
            }
        }

        statusObservation = engine.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }

        NowPlayingManager.shared.attach(to: self)
        offlineActivatedScope = AccountStore.shared.offlineScope
        networkObservation = DownloadManager.shared.$network.removeDuplicates().sink { [weak self] network in
            self?.networkState = network
        }
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
                // The system already silenced us; sync our state and UI.
                isPlaying = false
                NowPlayingManager.shared.updateElapsed(progress, rate: 0)
            }
        case .ended:
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            guard wasPlayingBeforeInterruption, options.contains(.shouldResume) else { return }
            wasPlayingBeforeInterruption = false
            try? AVAudioSession.sharedInstance().setActive(true)
            engine.play()
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
        if shuffleEnabled {
            reshuffle(keeping: startTrack)
            currentIndex = 0
        } else {
            currentIndex = tracks.firstIndex(where: { $0.id == startTrack.id }) ?? 0
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
        }
    }

    func togglePlayPause() {
        guard let track = currentTrack else { return }
        if isPlaying {
            engine.pause()
            isPlaying = false
            AudioSpectrum.shared.reset()
        } else if engine.currentItem == nil {
            // Restored session: re-resolve the source.
            startPlaying(track, indexUnchanged: true)
            return
        } else {
            engine.play()
            isPlaying = true
            scrobbleStartIfNeeded()
        }
        NowPlayingManager.shared.updateElapsed(progress, rate: isPlaying ? 1 : 0)
    }

    func pause() {
        engine.pause()
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

    func seek(to seconds: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        progress = seconds
        updateLyricsCursor(at: seconds)
        engine.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            guard let completion else { return }
            Task { @MainActor in completion() }
        }
        NowPlayingManager.shared.updateElapsed(seconds, rate: isPlaying ? 1 : 0)
    }

    func toggleShuffle() {
        guard !isFMMode else { return }
        shuffleEnabled.toggle()
        guard let current = currentTrack else { return }
        if shuffleEnabled {
            reshuffle(keeping: current)
            currentIndex = 0
        } else {
            currentIndex = queue.firstIndex(where: { $0.id == current.id }) ?? 0
        }
    }

    func cycleRepeatMode() {
        guard !isFMMode else { return }
        repeatMode = repeatMode.next
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
        if let idx = queue.firstIndex(where: { $0.id == track.id }), idx != currentIndex || shuffleEnabled {
            queue.remove(at: idx)
        }
        if let idx = shuffledQueue.firstIndex(where: { $0.id == track.id }) {
            shuffledQueue.remove(at: idx)
        }
    }

    /// Queue rows carry their occurrence, so a repeated song selects the row
    /// the listener clicked rather than its first occurrence.
    func jumpToUpcoming(at index: Int, matching trackID: Int) {
        guard let selected = upcomingCandidate(at: index, matching: trackID) else { return }
        switch selected.origin {
        case .inserted(let offset): playNextList.removeSubrange(0...offset)
        case .queue(let offset):
            if !playNextList.isEmpty { playNextList.removeAll() }
            currentIndex = offset
        case .fm: return
        }
        startPlaying(selected.track, indexUnchanged: selected.origin != .queue(currentIndex))
    }

    func removeUpcoming(at index: Int, matching trackID: Int) {
        guard let selected = upcomingCandidate(at: index, matching: trackID) else { return }
        if case .inserted(let offset) = selected.origin { playNextList.remove(at: offset) }
        else { removeFromUpcoming(selected.track) }
    }

    /// The row at `index` of `upcomingTracks`, if it still shows `trackID`.
    private func upcomingCandidate(at index: Int, matching trackID: Int) -> PlaybackQueueCandidate? {
        let candidates = PlaybackQueuePlan.next(queue: activeQueue, currentIndex: currentIndex, inserted: playNextList,
                                                fm: [], isFM: false, repeatAll: false, limit: max(0, index + 1))
        guard candidates.indices.contains(index), candidates[index].track.id == trackID else { return nil }
        return candidates[index]
    }

    // MARK: - Personal FM

    func startFM() {
        guard !isFMMode || !isPlaying else { return }
        recordRecent(.fm)
        isFMMode = true
        shuffleEnabled = false
        repeatMode = .off
        queue = []
        shuffledQueue = []
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
        if usesOfflineQueue {
            advanceOffline()
            return
        }
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
        pendingAutoAdvance = true
        startPlaying(track, indexUnchanged: true)
        if fmUpcoming.count < 1 {
            if let more = try? await NeteaseAPI.personalFM() {
                fmUpcoming.append(contentsOf: more)
            }
        }
    }

    // MARK: - Advancing

    private func advanceToNext(userInitiated: Bool) {
        if usesOfflineQueue, !nextCandidates().isEmpty {
            pendingAutoAdvance = !userInitiated
            advanceOffline()
            return
        }
        if isFMMode {
            Task { await fmAdvance() }
            return
        }
        if !playNextList.isEmpty {
            let track = playNextList.removeFirst()
            pendingAutoAdvance = !userInitiated
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
        pendingAutoAdvance = !userInitiated
        startPlaying(activeQueue[idx])
    }

    private func handleItemEnded() {
        scrobbleIfNeeded(completed: true)

        if sleepTimer.consumeEndOfCurrentTrack() {
            progress = duration
            updateLyricsCursor(at: duration)
            pause()
            engine.replaceCurrentItem(with: nil)
            releaseCurrentPlaybackResources()
            return
        }

        guard isPlaying else { return }

        if repeatMode == .one, !isFMMode {
            scrobbled = false
            seek(to: 0)
            engine.play()
            isPlaying = true
            return
        }
        advanceToNext(userInitiated: false)
    }

    // MARK: - Source resolution

    private func startPlaying(_ track: Track, indexUnchanged: Bool = false,
                              localLease: OfflinePlaybackLease? = nil) {
        offlineScan?.cancel()
        offlineScan = nil
        offlineScanID = UUID()
        offlineIssue = nil
        currentWasAdvanced = pendingAutoAdvance
        pendingAutoAdvance = false
        pendingAudioResourceLoader?.cancel()
        pendingAudioResourceLoader = nil
        scrobbleIfNeeded(completed: false)
        currentTrack = track
        progress = 0
        duration = track.duration
        servedQuality = nil
        unblockSource = nil
        currentUnblockSourceID = nil
        attemptedUnblockSources.removeAll()
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        isTrial = false
        lyrics = nil
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
            await resolveAndLoad(track, generation: generation, localLease: localLease)
        }
        Task {
            await loadLyrics(for: track, generation: generation)
        }
    }

    private func resolveAndLoad(_ track: Track, generation: Int,
                                localLease: OfflinePlaybackLease? = nil) async {
        let quality = SettingsManager.shared.audioQuality.rawValue
        let allowsUnblock = SettingsManager.shared.canResolveUnblockedTracks
        let cacheEnabled = SettingsManager.shared.enableAudioCache

        // A downloaded copy beats the network, and is all there is without one.
        if let lease = await acquireOfflineLease(for: track, generation: generation, reusing: localLease) {
            await playOfflineFile(lease, for: track, generation: generation)
            return
        }
        guard generation == resolveGeneration else { return }

        if cacheEnabled {
            do {
                if let cached = try await AudioCache.shared.entry(
                    for: track.id,
                    requestedQuality: quality,
                    allowsUnblock: allowsUnblock
                ) {
                    guard generation == resolveGeneration else { return }
                    let lease = await AudioCache.shared.retain(cached)
                    guard generation == resolveGeneration else {
                        releaseAudioCacheLease(lease)
                        return
                    }
                    servedQuality = cached.metadata.servedQuality
                    if case .unblock(let source) = cached.metadata.source {
                        unblockSource = source
                    }
                    _ = await installResolvedAsset(
                        AVURLAsset(url: cached.fileURL),
                        for: track,
                        generation: generation,
                        durationMS: nil,
                        cacheLease: lease
                    )
                    return
                }
            } catch {
                print("Audio cache lookup failed: \(error)")
            }
        }

        // Without a network, the cache is the last place to look.
        if usesOfflineQueue {
            if cacheEnabled, await loadFallbackCache(for: track, generation: generation, allowsUnblock: allowsUnblock) { return }
            guard generation == resolveGeneration else { return }
            unavailableOffline(track, generation: generation)
            return
        }

        var data: SongURLData?
        do {
            data = try await NeteaseAPI.songURL(ids: [track.id], level: quality).first
            if data?.url == nil, quality != AudioQuality.standard.rawValue {
                data = try await NeteaseAPI.songURL(ids: [track.id], level: AudioQuality.standard.rawValue).first
            }
        } catch {
            guard generation == resolveGeneration else { return }
            // A download covers a request that died on the network. Anything
            // else keeps upstream's path: third-party sources, then the cache.
            if ConnectivityFailure.matches(error) {
                if let lease = await acquireOfflineLease(for: track, generation: generation, anyQuality: true) {
                    await playOfflineFile(lease, for: track, generation: generation)
                    return
                }
                guard generation == resolveGeneration else { return }
                if usesOfflineQueue {
                    if cacheEnabled, await loadFallbackCache(for: track, generation: generation, allowsUnblock: allowsUnblock) { return }
                    guard generation == resolveGeneration else { return }
                    unavailableOffline(track, generation: generation)
                    return
                }
            }
        }
        guard generation == resolveGeneration else { return }

        var resolvedURL: URL?
        if let urlString = data?.url {
            resolvedURL = URL(string: urlString.replacingOccurrences(of: "http://", with: "https://"))
        }

        // NetEase refused — try third-party sources (UnblockNeteaseMusic-style).
        if resolvedURL == nil || data?.freeTrialInfo != nil, allowsUnblock {
            if await resolveAndLoadUnblocked(track, generation: generation) { return }
        }
        guard generation == resolveGeneration else { return }

        guard let url = resolvedURL else {
            if cacheEnabled, await loadFallbackCache(
                for: track,
                generation: generation,
                allowsUnblock: allowsUnblock
            ) {
                return
            }
            handleUnplayable(track)
            return
        }

        servedQuality = data?.level
        if data?.freeTrialInfo != nil {
            isTrial = true
            ToastCenter.shared.show(String(localized: "VIP 歌曲，当前为试听片段"))
        }
        _ = await loadResolvedURL(track, url: url, durationMS: data?.time, generation: generation)
    }

    private func resolveAndLoadUnblocked(
        _ track: Track,
        generation: Int,
        requiresActivePlayback: Bool = false
    ) async -> Bool {
        let enabledSources = SettingsManager.shared.enabledAudioSourceIDs
        guard !enabledSources.isEmpty else { return false }

        guard generation == resolveGeneration,
              !requiresActivePlayback || isPlaying
        else { return false }

        let resolution = await UnblockService.resolve(
            track,
            enabledSources: enabledSources,
            excluding: attemptedUnblockSources
        )
        attemptedUnblockSources.formUnion(resolution.attemptedSources)
        guard let unblocked = resolution.source else { return false }
        guard generation == resolveGeneration,
              !requiresActivePlayback || isPlaying
        else { return false }

        currentUnblockSourceID = unblocked.id
        unblockSource = unblocked.displayName
        servedQuality = nil
        isTrial = false

        let loadResult = await loadResolvedURL(
            track,
            url: unblocked.url,
            durationMS: nil,
            generation: generation
        )
        guard case .loaded = loadResult else { return false }

        ToastCenter.shared.show(String(localized: "已使用第三方音源：\(unblocked.displayName)"))
        return true
    }

    private func handleUnplayable(_ track: Track) {
        consecutiveFailures += 1
        let reason = track.playability(privilege: nil,
                                       isLoggedIn: AccountStore.shared.isLoggedIn,
                                       vipType: AccountStore.shared.vipType).reason
        ToastCenter.shared.show(String(localized: "《\(track.name)》无法播放\(reason.map { "：\($0)" } ?? "")"))
        guard isPlaying else {
            engine.replaceCurrentItem(with: nil)
            releaseCurrentPlaybackResources()
            return
        }
        if consecutiveFailures < 5 {
            advanceToNext(userInitiated: false)
        } else {
            isPlaying = false
        }
    }

    private func loadResolvedURL(
        _ track: Track,
        url: URL,
        durationMS: Int?,
        generation: Int
    ) async -> ResolvedURLLoadResult {
        consecutiveFailures = 0

        var asset = AVURLAsset(url: url)
        var resourceLoader: CachingAudioResourceLoader?
        if SettingsManager.shared.enableAudioCache, !isTrial {
            let cacheLimitMB = await SettingsManager.shared.effectiveAudioCacheSizeMB()
            guard generation == resolveGeneration else { return .superseded }
            let source: AudioCacheSource = unblockSource.map(AudioCacheSource.unblock) ?? .netease
            do {
                let loader = try CachingAudioResourceLoader(
                    remoteURL: url,
                    trackID: track.id,
                    requestedQuality: SettingsManager.shared.audioQuality.rawValue,
                    servedQuality: servedQuality,
                    source: source,
                    maximumCacheSizeMB: cacheLimitMB
                )
                guard generation == resolveGeneration else {
                    loader.cancel()
                    return .superseded
                }
                let cachedAsset = AVURLAsset(url: loader.assetURL)
                loader.attach(to: cachedAsset)
                pendingAudioResourceLoader = loader
                resourceLoader = loader
                asset = cachedAsset
            } catch {
                print("Audio source will play without caching: \(error)")
            }
        }

        return await installResolvedAsset(
            asset,
            for: track,
            generation: generation,
            durationMS: durationMS,
            resourceLoader: resourceLoader
        )
    }

    private func loadFallbackCache(
        for track: Track,
        generation: Int,
        allowsUnblock: Bool
    ) async -> Bool {
        do {
            guard let cached = try await AudioCache.shared.fallbackEntry(
                for: track.id,
                allowsUnblock: allowsUnblock
            ) else { return false }
            guard generation == resolveGeneration else { return true }
            let lease = await AudioCache.shared.retain(cached)
            guard generation == resolveGeneration else {
                releaseAudioCacheLease(lease)
                return true
            }
            servedQuality = cached.metadata.servedQuality
            if case .unblock(let source) = cached.metadata.source {
                unblockSource = source
            }
            _ = await installResolvedAsset(
                AVURLAsset(url: cached.fileURL),
                for: track,
                generation: generation,
                durationMS: nil,
                cacheLease: lease
            )
            return true
        } catch {
            print("Audio cache fallback lookup failed: \(error)")
            return false
        }
    }

    private func installResolvedAsset(
        _ asset: AVURLAsset,
        for track: Track,
        generation: Int,
        durationMS: Int?,
        resourceLoader: CachingAudioResourceLoader? = nil,
        cacheLease: UUID? = nil,
        offlineLease: OfflinePlaybackLease? = nil,
        resumeAt: TimeInterval = 0
    ) async -> ResolvedURLLoadResult {
        // Resolve the asset's audio track before the item goes live: an audio mix
        // attached after playback starts is silently ignored, so the spectrum tap
        // has to be spliced in here or not at all. Unsupported sources and iOS
        // cache hits play untapped and use the decorative UI fallback.
        #if os(iOS)
        // Cached files already have a complete local media source. Keeping their
        // playback path free of a MediaToolbox processing tap avoids rebuilding
        // the custom render pipeline on every rapid cache-to-cache switch.
        let assetTrack = asset.url.isFileURL
            ? nil
            : await loadAudioTrack(from: asset, timeout: 2)
        #else
        let assetTrack = await loadAudioTrack(from: asset, timeout: 2)
        #endif
        guard generation == resolveGeneration,
              resourceLoader.map({ pendingAudioResourceLoader === $0 }) ?? true else {
            resourceLoader?.cancel()
            if let cacheLease {
                releaseAudioCacheLease(cacheLease)
            }
            if let offlineLease { Task { try? await OfflineStore.shared.release(offlineLease) } }
            return .superseded
        }

        let item = AVPlayerItem(asset: asset)
        if let assetTrack,
           let mix = AudioSpectrum.shared.makeAudioMix(for: assetTrack) {
            item.audioMix = mix
        } else {
            AudioSpectrum.shared.markUntappable()
        }

        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        let sourceID = currentUnblockSourceID
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let connectivity = item.error.map(ConnectivityFailure.matches) ?? false
            Task { @MainActor in
                if let sourceID {
                    self?.handleUnblockItemFailure(track: track, generation: generation, sourceID: sourceID)
                } else if connectivity {
                    self?.handleConnectivityItemFailure(track: track, generation: generation)
                }
            }
        }

        if let old = endObserver {
            NotificationCenter.default.removeObserver(old)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleItemEnded()
            }
        }
        let previousResourceLoader = audioResourceLoader
        let previousCacheLease = audioCacheLease
        let previousOfflineLease = offlinePlaybackLease
        if resourceLoader != nil {
            pendingAudioResourceLoader = nil
        }
        audioResourceLoader = resourceLoader
        audioCacheLease = cacheLease
        offlinePlaybackLease = offlineLease
        engine.replaceCurrentItem(with: item)
        previousResourceLoader?.cancel()
        if let previousCacheLease {
            releaseAudioCacheLease(previousCacheLease)
        }
        if let previousOfflineLease { Task { try? await OfflineStore.shared.release(previousOfflineLease) } }
        if resumeAt > 0 {
            let time = CMTime(seconds: min(resumeAt, max(0, duration - 0.1)), preferredTimescale: 600)
            _ = await engine.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            guard generation == resolveGeneration else { return .superseded }
        }
        if isPlaying {
            engine.play()
            scrobbleStartIfNeeded()
        }

        if let durationMS, durationMS > 0 {
            duration = TimeInterval(durationMS) / 1000
            NowPlayingManager.shared.updateMetadata(for: track, duration: duration)
        }
        return .loaded
    }

    private func handleUnblockItemFailure(
        track: Track,
        generation: Int,
        sourceID: AudioSourceID
    ) {
        guard generation == resolveGeneration,
              currentTrack?.id == track.id,
              currentUnblockSourceID == sourceID
        else { return }

        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        currentUnblockSourceID = nil
        unblockSource = nil
        engine.replaceCurrentItem(with: nil)
        releaseCurrentPlaybackResources()
        AudioSpectrum.shared.beginPreparing()

        guard isPlaying else {
            return
        }

        Task {
            let loaded = await resolveAndLoadUnblocked(
                track,
                generation: generation,
                requiresActivePlayback: true
            )
            guard isPlaying else { return }
            guard loaded else {
                guard generation == resolveGeneration else { return }
                handleUnplayable(track)
                return
            }
        }
    }

    private func releaseAudioCacheLease(_ leaseID: UUID) {
        Task {
            do {
                try await AudioCache.shared.release(leaseID)
            } catch {
                print("Audio cache could not release its playback lease: \(error)")
            }
        }
    }

    private func releaseCurrentPlaybackResources() {
        let resourceLoader = audioResourceLoader
        let cacheLease = audioCacheLease
        audioResourceLoader = nil
        audioCacheLease = nil
        resourceLoader?.cancel()
        if let cacheLease {
            releaseAudioCacheLease(cacheLease)
        }
        releaseOfflineLease()
    }

    /// Resolves the asset's audio track, giving up after `timeout` so a slow or
    /// uncooperative source delays playback no longer than it would today.
    private func loadAudioTrack(from asset: AVURLAsset, timeout: TimeInterval) async -> AVAssetTrack? {
        await withTaskGroup(of: AVAssetTrack?.self) { group in
            group.addTask {
                try? await asset.loadTracks(withMediaType: .audio).first
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func loadLyrics(for track: Track, generation: Int) async {
        let scope = offlineAccountScope
        if let scope, let saved = await OfflineMetadataStore.shared.lyrics(trackID: track.id, scope: scope) {
            guard generation == resolveGeneration else { return }
            lyrics = LyricsParser.parse(saved)
            updateLyricsCursor(at: progress)
        }
        guard !usesOfflineQueue else { return }
        let response = try? await NeteaseAPI.lyric(id: track.id)
        guard generation == resolveGeneration, let response else { return }
        lyrics = LyricsParser.parse(response)
        updateLyricsCursor(at: progress)
        if let scope, DownloadManager.shared.isDownloaded(trackID: track.id) {
            try? await OfflineMetadataStore.shared.save(lyrics: response, trackID: track.id, scope: scope)
        }
    }

    // MARK: - Offline playback

    /// Downloads belong to one account; see `activateAccount`.
    private var offlineAccountScope: String? { AccountStore.shared.offlineScope }
    private var usesOfflineQueue: Bool { networkState.isKnown && !networkState.connected }

    private func nextCandidates() -> [PlaybackQueueCandidate] {
        PlaybackQueuePlan.next(queue: activeQueue, currentIndex: currentIndex, inserted: playNextList,
                               fm: fmUpcoming, isFM: isFMMode, repeatAll: repeatMode == .all)
    }

    /// A downloaded copy of the track. Online it must match the chosen quality
    /// or better; offline, any quality will do.
    private func acquireOfflineLease(for track: Track, generation: Int, reusing lease: OfflinePlaybackLease? = nil,
                                     anyQuality: Bool = false) async -> OfflinePlaybackLease? {
        let scope = offlineAccountScope
        var lease = lease
        if lease == nil, let scope {
            lease = try? await OfflineStore.shared.acquire(accountScope: scope, trackID: track.id,
                preferredQuality: SettingsManager.shared.audioQuality.rawValue,
                allowLowerQuality: anyQuality || !networkState.connected)
        }
        guard let lease else { return nil }
        guard generation == resolveGeneration, scope == offlineAccountScope,
              lease.descriptor.identity.accountScope == scope else {
            try? await OfflineStore.shared.release(lease)
            return nil
        }
        return lease
    }

    private func playOfflineFile(_ lease: OfflinePlaybackLease, for track: Track, generation: Int,
                                 resumeAt: TimeInterval = 0) async {
        consecutiveFailures = 0
        servedQuality = lease.descriptor.identity.quality
        _ = await installResolvedAsset(AVURLAsset(url: lease.url), for: track, generation: generation,
                                       durationMS: Int(lease.descriptor.duration * 1000),
                                       offlineLease: lease, resumeAt: resumeAt)
    }

    /// The stream died for lack of network. A download of the same song picks
    /// up where it stopped; otherwise the song is reported or skipped.
    private func handleConnectivityItemFailure(track: Track, generation: Int) {
        guard generation == resolveGeneration, currentTrack?.id == track.id else { return }
        let position = max(progress, livePlaybackTime)
        resolveGeneration += 1
        let recovery = resolveGeneration
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        engine.replaceCurrentItem(with: nil)
        releaseCurrentPlaybackResources()
        Task {
            if let lease = await acquireOfflineLease(for: track, generation: recovery, anyQuality: true) {
                await playOfflineFile(lease, for: track, generation: recovery, resumeAt: position)
                return
            }
            guard recovery == resolveGeneration else { return }
            unavailableOffline(track, generation: recovery, autoAdvance: currentWasAdvanced && position < 0.5)
        }
    }

    private func releaseOfflineLease() {
        guard let lease = offlinePlaybackLease else { return }
        offlinePlaybackLease = nil
        Task { try? await OfflineStore.shared.release(lease) }
    }

    private func unavailableOffline(_ track: Track, generation: Int, autoAdvance: Bool? = nil) {
        guard generation == resolveGeneration else { return }
        if autoAdvance ?? currentWasAdvanced {
            advanceOffline(initialSkipped: 1, excludingFailedCurrent: true)
            return
        }
        engine.replaceCurrentItem(with: nil)
        releaseCurrentPlaybackResources()
        isPlaying = false
        isBuffering = false
        offlineIssue = .init(kind: .missingTrack, trackName: track.name)
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
    }

    func playNextAvailableOffline() {
        offlineIssue = nil
        advanceOffline()
    }

    /// Walks the upcoming list for the first song that is on this device.
    private func advanceOffline(initialSkipped: Int = 0, excludingFailedCurrent: Bool = false) {
        offlineScan?.cancel()
        let requestID = UUID()
        offlineScanID = requestID
        resolveGeneration += 1
        let generation = resolveGeneration
        let scope = offlineAccountScope
        var candidates = nextCandidates()
        if excludingFailedCurrent { candidates.removeAll { $0.origin == .queue(currentIndex) } }
        engine.replaceCurrentItem(with: nil)
        releaseCurrentPlaybackResources()
        isPlaying = false
        offlineScan = Task { [weak self] in
            guard let self, !Task.isCancelled, self.offlineScanID == requestID else { return }
            let selected = try? await OfflineQueueSelector.firstAvailable(candidates, scope: scope,
                quality: SettingsManager.shared.audioQuality.rawValue, store: .shared,
                isCached: { await self.isCachedForOffline($0) })
            guard !Task.isCancelled, self.offlineScanID == requestID, self.resolveGeneration == generation,
                  self.offlineAccountScope == scope else {
                if let lease = selected?.lease { try? await OfflineStore.shared.release(lease) }
                return
            }
            self.offlineScan = nil
            guard let selected else {
                self.pendingAutoAdvance = false
                self.offlineIssue = .init(kind: .emptyQueue, trackName: nil)
                self.isBuffering = false
                NowPlayingManager.shared.updateElapsed(self.progress, rate: 0)
                return
            }
            // The queue may have been edited while the scan ran.
            guard self.stillHolds(selected.candidate) else {
                if let lease = selected.lease { try? await OfflineStore.shared.release(lease) }
                self.advanceOffline(initialSkipped: initialSkipped, excludingFailedCurrent: excludingFailedCurrent)
                return
            }
            switch selected.candidate.origin {
            case .inserted(let index): self.playNextList.removeSubrange(0...index)
            case .queue(let index):
                if !self.playNextList.isEmpty { self.playNextList.removeAll() }
                self.currentIndex = index
            case .fm(let index): self.fmUpcoming.removeSubrange(0...index)
            }
            let skipped = initialSkipped + selected.skipped
            self.pendingAutoAdvance = true
            self.startPlaying(selected.candidate.track, localLease: selected.lease)
            if skipped > 0 { ToastCenter.shared.show(String(localized: "已跳过 \(skipped) 首未下载歌曲")) }
        }
    }

    /// Whether the song cache can play the track without the network.
    private func isCachedForOffline(_ trackID: Int) async -> Bool {
        guard SettingsManager.shared.enableAudioCache else { return false }
        let allowsUnblock = SettingsManager.shared.canResolveUnblockedTracks
        return (try? await AudioCache.shared.fallbackEntry(for: trackID, allowsUnblock: allowsUnblock)) != nil
    }

    private func stillHolds(_ candidate: PlaybackQueueCandidate) -> Bool {
        switch candidate.origin {
        case .inserted(let index): return playNextList.indices.contains(index) && playNextList[index].id == candidate.track.id
        case .queue(let index): return activeQueue.indices.contains(index) && activeQueue[index].id == candidate.track.id
        case .fm(let index): return fmUpcoming.indices.contains(index) && fmUpcoming[index].id == candidate.track.id
        }
    }

    /// Downloads belong to one account. Audio leased under the previous
    /// account stops, and the offline queue scan starts over.
    func activateAccount(scope: String?) {
        guard offlineActivatedScope != scope else { return }
        offlineActivatedScope = scope
        offlineScan?.cancel()
        offlineScan = nil
        offlineScanID = UUID()
        offlineIssue = nil
        guard offlinePlaybackLease != nil else { return }
        resolveGeneration += 1
        engine.replaceCurrentItem(with: nil)
        releaseCurrentPlaybackResources()
        isPlaying = false
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
    }

    // MARK: - Scrobble

    private func scrobbleStartIfNeeded() {
        guard let track = currentTrack, !startScrobbled else { return }
        startScrobbled = true
        let trackID = track.id
        let sourceID = source.sourceID
        Task.detached {
            await NeteaseAPI.scrobbleStart(trackID: trackID, sourceID: sourceID)
        }
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

    func resolve(_ context: PlayContext) async throws -> (tracks: [Track], source: PlaySource)? {
        try await OfflineContextResolver.resolve(context, offline: usesOfflineQueue) { try await resolveOnline(context) }
    }

    private func resolveOnline(_ context: PlayContext) async throws -> (tracks: [Track], source: PlaySource)? {
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

    private struct PersistedState: Codable {
        var queue: [Track]
        var currentID: Int?
        var repeatMode: String
        var shuffle: Bool
        /// Optional so state files written before recents existed still decode.
        var recentContexts: [PlayContext]?
    }

    private func persistState() {
        let state = PersistedState(
            queue: Array(queue.prefix(1000)),
            currentID: currentTrack?.id,
            repeatMode: repeatMode.rawValue,
            shuffle: shuffleEnabled,
            recentContexts: recentContexts
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
        shuffleEnabled = state.shuffle
        if shuffleEnabled {
            shuffledQueue = queue.shuffled()
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

    private static var stateFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kumone", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("player-state.json")
    }
}
#endif
