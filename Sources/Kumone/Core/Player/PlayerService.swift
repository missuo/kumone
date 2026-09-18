import AVFoundation
import Combine
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
enum PlaySource: Codable, Equatable {
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

    var source: PlaySource {
        switch kind {
        case .playlist: return .playlist(id)
        case .album: return .album(id)
        case .artist: return .artist(id)
        case .daily: return .daily
        case .cloud: return .cloud
        default: return .none
        }
    }

    var downloadCollectionID: String? {
        switch kind {
        case .playlist: return "playlist:\(id)"
        case .album: return "album:\(id)"
        default: return nil
        }
    }

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

    @Published private(set) var queue: [Track] = [] { didSet { sessionSnapshotDirty = true } }
    @Published private(set) var shuffledQueue: [Track] = [] { didSet { sessionSnapshotDirty = true } }
    @Published private(set) var playNextList: [Track] = [] { didSet { sessionSnapshotDirty = true } }
    @Published private(set) var currentIndex = -1
    @Published private(set) var currentTrack: Track?
    @Published private(set) var source: PlaySource = .none { didSet { sessionSnapshotDirty = true } }
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var servedQuality: String?
    @Published private(set) var unblockSource: String?
    @Published private(set) var isTrial = false
    @Published var offlineIssue: OfflinePlaybackIssue?
    let clock = PlaybackClock()
    let lyricsCursor = LyricsCursor()
    let sleepTimer = SleepTimer()
    /// Passthrough to the clock so existing `progress` reads/writes keep working.
    var progress: TimeInterval {
        get { clock.progress }
        set { clock.progress = newValue }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet {
            UserDefaults.standard.set(repeatMode.rawValue, forKey: "player.repeat")
            if !isRestoringState { sessionSnapshotDirty = true; persistState() }
        }
    }

    @Published private(set) var shuffleEnabled = false { didSet { sessionSnapshotDirty = true } }
    @Published var volume: Float = 1 {
        didSet {
            engine.volume = volume
            UserDefaults.standard.set(volume, forKey: "player.volume")
        }
    }

    @Published private(set) var isFMMode = false { didSet { sessionSnapshotDirty = true } }
    @Published private(set) var fmUpcoming: [Track] = [] { didSet { sessionSnapshotDirty = true } }
    /// Where playback was most recently started from, newest first —
    /// surfaced as "Recently Played" in the Dock menu.
    @Published private(set) var recentContexts: [PlayContext] = [] { didSet { sessionSnapshotDirty = true } }
    @Published private(set) var lyrics: ParsedLyrics?
    @Published var activePanel: RightPanel?
    @Published var showNowPlaying = false

    /// The list the player is walking through (shuffled or ordered).
    var activeQueue: [Track] { shuffleEnabled ? shuffledQueue : queue }

    var upcomingTracks: [Track] {
        if isFMMode { return fmUpcoming }
        guard !activeQueue.isEmpty, currentIndex >= 0 else { return playNextList }
        let rest = activeQueue.suffix(from: min(currentIndex + 1, activeQueue.count))
        return playNextList + Array(rest.prefix(200))
    }

    var hasCurrentTrack: Bool { currentTrack != nil }

    // MARK: - Engine

    private let engine = AVPlayer()
    private var offlinePlaybackLease: OfflinePlaybackLease?
    private var playbackCacheSession: PlaybackCacheSession?
    private var cacheArtworkTask: Task<Void, Never>?
    private var prefetchRefresh: Task<Void, Never>?
    private var offlineScan: Task<Void, Never>?
    private var offlineScanID = UUID()
    private var queueRevision = 0
    private var currentWasAdvanced = false
    private var networkState = DownloadNetworkState.unknown
    private var networkObservation: AnyCancellable?
    private var itemStatusObservation: NSKeyValueObservation?
    private var stateScope: String?
    private var sessionID = UUID()
    private var sessionSnapshotDirty = true
    private var persistenceRevision: UInt64 = 0
    private var lastCheckpoint: TimeInterval = 0
    private var isRestoringState = false

    /// Live playback position straight from the player, for smooth per-frame
    /// karaoke highlighting (the published `progress` is intentionally coarse).
    var livePlaybackTime: TimeInterval {
        let t = engine.currentTime().seconds
        return t.isFinite ? t : progress
    }
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var resolveGeneration = 0
    private var consecutiveFailures = 0
    private var scrobbled = false
    private var startScrobbled = false

    private init() {
        engine.actionAtItemEnd = .pause
        sleepTimer.onDeadlineReached = { [weak self] in
            self?.pause()
        }
        volume = KumonePaths.isOfflineUITest ? 0 : (UserDefaults.standard.object(forKey: "player.volume") as? Float ?? 0.8)
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
                guard let self, !self.isScrubbing, self.engine.currentItem != nil else { return }
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
                    if abs(seconds - self.lastCheckpoint) >= 5 { self.checkpointPosition() }
                    self.refreshPrefetchSoon()
                }
            }
        }

        statusObservation = engine.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self?.refreshPrefetchSoon()
            }
        }

        NowPlayingManager.shared.attach(to: self)
        stateScope = AccountStore.shared.offlineScope
        restoreState()
        networkObservation = DownloadManager.shared.$network.removeDuplicates().sink { [weak self] network in
            guard let self else { return }
            self.networkState = network
            self.refreshPrefetchSoon()
        }
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
        startPlaying(activeQueue[currentIndex], autoAdvance: track == nil && tracks.count > 1)
    }

    func playTrack(_ track: Track) {
        if let idx = activeQueue.firstIndex(where: { $0.id == track.id }) {
            currentIndex = idx
            startPlaying(track)
        } else {
            play(tracks: [track], source: .none, startAt: track)
        }
    }

    /// Insert a track right after the current one.
    func addToPlayNext(_ track: Track, playNow: Bool = false) {
        playNextList.append(track)
        persistState()
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
            // Resume a saved position; a track ended by the sleep timer restarts.
            startPlaying(track, indexUnchanged: true, resumeAt: progress >= duration ? 0 : progress)
            return
        } else {
            engine.play()
            isPlaying = true
            scrobbleStartIfNeeded()
        }
        NowPlayingManager.shared.updateElapsed(progress, rate: isPlaying ? 1 : 0)
        checkpointPosition()
        refreshPrefetchSoon()
    }

    func pause() {
        engine.pause()
        isPlaying = false
        AudioSpectrum.shared.reset()
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
        checkpointPosition()
        refreshPrefetchSoon()
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
        PlaybackCacheController.shared.updatePlayback(upcoming: prefetchTracks, isPlaying: isPlaying, isBuffering: true, ready: false)
        progress = seconds
        checkpointPosition()
        updateLyricsCursor(at: seconds)
        engine.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.refreshPrefetchSoon(); completion?() }
        }
        NowPlayingManager.shared.updateElapsed(seconds, rate: isPlaying ? 1 : 0)
    }

    func toggleShuffle() {
        guard !isFMMode else { return }
        defer { persistState() }
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
        if let index = nextCandidates.firstIndex(where: { $0.track.id == track.id }) {
            jumpToUpcoming(at: index, matching: track.id)
            return
        }
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

    /// Queue rows carry their occurrence, so a repeated song selects the row
    /// the listener clicked rather than jumping back to its first occurrence.
    func jumpToUpcoming(at index: Int, matching trackID: Int) {
        let candidates = nextCandidates
        guard candidates.indices.contains(index), candidates[index].track.id == trackID else { return }
        let selected = candidates[index]
        switch selected.origin {
        case .inserted(let offset): playNextList.removeSubrange(0...offset)
        case .queue(let offset):
            if !playNextList.isEmpty { playNextList.removeAll() }
            currentIndex = offset
        case .fm(let offset): fmUpcoming.removeSubrange(0...offset)
        }
        startPlaying(selected.track)
    }

    func removeFromUpcoming(_ track: Track) {
        guard let index = nextCandidates.firstIndex(where: { $0.track.id == track.id }) else { return }
        removeUpcoming(at: index, matching: track.id)
    }

    func removeUpcoming(at index: Int, matching trackID: Int) {
        let candidates = nextCandidates
        guard candidates.indices.contains(index), candidates[index].track.id == trackID else { return }
        let selected = candidates[index]
        switch selected.origin {
        case .inserted(let offset): playNextList.remove(at: offset)
        case .fm(let offset): fmUpcoming.remove(at: offset)
        case .queue(let offset):
            guard offset != currentIndex else { return }
            if shuffleEnabled {
                shuffledQueue.remove(at: offset)
                if let original = queue.firstIndex(where: { $0.id == selected.track.id }) { queue.remove(at: original) }
            } else { queue.remove(at: offset) }
            if offset < currentIndex { currentIndex -= 1 }
        }
        persistState()
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
        if usesOfflineQueue { advanceOffline(); return }
        let scope = offlineAccountScope
        let generation = resolveGeneration
        if fmUpcoming.isEmpty {
            for attempt in 0..<3 {
                do {
                    let tracks = try await NeteaseAPI.personalFM()
                    guard scope == offlineAccountScope, generation == resolveGeneration, isFMMode else { return }
                    if !tracks.isEmpty { fmUpcoming = tracks; break }
                } catch {
                    guard scope == offlineAccountScope, generation == resolveGeneration, isFMMode else { return }
                    if Self.isConnectivityFailure(error) { advanceOffline(); return }
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
        startPlaying(track, indexUnchanged: true, autoAdvance: true)
        let playingGeneration = resolveGeneration
        if fmUpcoming.count < 1 {
            if let more = try? await NeteaseAPI.personalFM() {
                guard scope == offlineAccountScope, playingGeneration == resolveGeneration, isFMMode else { return }
                fmUpcoming.append(contentsOf: more)
                persistState()
            }
        }
    }

    // MARK: - Advancing

    private var usesOfflineQueue: Bool { networkState.isKnown && !networkState.connected }

    private var nextCandidates: [PlaybackQueueCandidate] {
        PlaybackQueuePlan.next(queue: activeQueue, currentIndex: currentIndex, inserted: playNextList,
                               fm: fmUpcoming, isFM: isFMMode, repeatAll: repeatMode == .all)
    }

    private var prefetchTracks: [Track] {
        if repeatMode == .one, !isFMMode { return [] }
        return nextCandidates.prefix(5).map(\.track)
    }

    private func refreshPrefetchSoon() {
        guard prefetchRefresh == nil else { return }
        prefetchRefresh = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            self.prefetchRefresh = nil
            let position = self.livePlaybackTime
            let buffered = self.engine.currentItem?.loadedTimeRanges.compactMap { value -> Double? in
                let range = value.timeRangeValue
                let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
                return start <= position && end >= position ? end - position : nil
            }.max() ?? 0
            let ordinaryStreamReady = self.playbackCacheSession == nil && self.engine.currentItem?.status == .readyToPlay
                && buffered >= min(30, max(0.5, self.duration - position))
            PlaybackCacheController.shared.updatePlayback(upcoming: self.prefetchTracks,
                isPlaying: self.isPlaying && !self.usesOfflineQueue, isBuffering: self.isBuffering,
                ready: self.offlinePlaybackLease != nil || ordinaryStreamReady)
        }
    }

    func playNextAvailableOffline() {
        offlineIssue = nil
        advanceOffline()
    }

    private func advanceOffline(initialSkipped: Int = 0, excludingFailedCurrent: Bool = false) {
        offlineScan?.cancel()
        let requestID = UUID()
        offlineScanID = requestID
        let revision = queueRevision
        resolveGeneration += 1
        let generation = resolveGeneration
        let scope = offlineAccountScope
        var candidates = nextCandidates
        if excludingFailedCurrent {
            candidates.removeAll { $0.origin == .queue(currentIndex) }
        }
        engine.replaceCurrentItem(with: nil)
        playbackCacheSession = nil
        cacheArtworkTask?.cancel()
        if let lease = offlinePlaybackLease {
            offlinePlaybackLease = nil
            Task { try? await OfflineStore.shared.release(lease) }
        }
        isPlaying = false
        let stopped = PlaybackCacheController.shared.stop()
        offlineScan = Task { [weak self] in
            await stopped.value
            guard let self, !Task.isCancelled, self.offlineScanID == requestID else { return }
            let selected: OfflineQueueSelection?
            do {
                if let scope {
                    selected = try await OfflineQueueSelector.firstAvailable(candidates, scope: scope,
                        quality: SettingsManager.shared.audioQuality.rawValue, store: .shared)
                } else { selected = nil }
            } catch { selected = nil }
            guard !Task.isCancelled, self.offlineScanID == requestID, self.resolveGeneration == generation,
                  self.offlineAccountScope == scope else {
                if let selected { try? await OfflineStore.shared.release(selected.lease) }
                return
            }
            guard self.queueRevision == revision else {
                if let selected { try? await OfflineStore.shared.release(selected.lease) }
                self.advanceOffline(initialSkipped: initialSkipped, excludingFailedCurrent: excludingFailedCurrent)
                return
            }
            self.offlineScan = nil
            guard let selected else {
                self.offlineIssue = .init(kind: .emptyQueue, trackName: nil)
                self.isBuffering = false
                NowPlayingManager.shared.updateElapsed(self.progress, rate: 0)
                self.checkpointPosition()
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
            self.startPlaying(selected.candidate.track, autoAdvance: true, localLease: selected.lease)
            if skipped > 0 { ToastCenter.shared.show(String(localized: "已跳过 \(skipped) 首未缓存歌曲")) }
        }
    }

    private func unavailableOffline(_ track: Track, generation: Int, autoAdvance: Bool) {
        guard generation == resolveGeneration else { return }
        if autoAdvance { advanceOffline(initialSkipped: 1, excludingFailedCurrent: true); return }
        engine.replaceCurrentItem(with: nil)
        playbackCacheSession = nil
        PlaybackCacheController.shared.stop()
        isPlaying = false
        isBuffering = false
        offlineIssue = .init(kind: .missingTrack, trackName: track.name)
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
        checkpointPosition()
    }

    nonisolated private static func isConnectivityFailure(_ error: Error) -> Bool {
        AudioTransferCoordinator.isConnectivityFailure(error)
    }

    private func advanceToNext(userInitiated: Bool) {
        if !isFMMode, playNextList.isEmpty, repeatMode != .all,
           currentIndex + 1 >= activeQueue.count {
            if userInitiated { ToastCenter.shared.show(String(localized: "已经是最后一首了")) }
            else {
                isPlaying = false
                NowPlayingManager.shared.updateElapsed(progress, rate: 0)
            }
            return
        }
        if usesOfflineQueue { advanceOffline(); return }
        if isFMMode {
            Task { await fmAdvance() }
            return
        }
        if !playNextList.isEmpty {
            let track = playNextList.removeFirst()
            startPlaying(track, indexUnchanged: true, autoAdvance: true)
            return
        }
        guard !activeQueue.isEmpty else { return }
        var idx = currentIndex + 1
        if idx >= activeQueue.count {
            idx = 0
        }
        currentIndex = idx
        startPlaying(activeQueue[idx], autoAdvance: true)
    }

    private func handleItemEnded() {
        scrobbleIfNeeded(completed: true)

        if sleepTimer.consumeEndOfCurrentTrack() {
            progress = duration
            updateLyricsCursor(at: duration)
            pause()
            engine.replaceCurrentItem(with: nil)
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

    private func startPlaying(_ track: Track, indexUnchanged: Bool = false, resumeAt: TimeInterval = 0,
                              autoAdvance: Bool = false, localLease: OfflinePlaybackLease? = nil) {
        offlineScan?.cancel()
        offlineScan = nil
        offlineScanID = UUID()
        offlineIssue = nil
        currentWasAdvanced = autoAdvance
        scrobbleIfNeeded(completed: false)
        engine.replaceCurrentItem(with: nil)
        playbackCacheSession = nil
        cacheArtworkTask?.cancel()
        PlaybackCacheController.shared.protect(trackID: track.id, scope: offlineAccountScope)
        let cacheStopped = PlaybackCacheController.shared.stop()
        if let lease = offlinePlaybackLease {
            offlinePlaybackLease = nil
            Task { try? await OfflineStore.shared.release(lease) }
        }
        currentTrack = track
        progress = max(0, resumeAt)
        duration = track.duration
        servedQuality = nil
        unblockSource = nil
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
            await cacheStopped.value
            guard generation == resolveGeneration else {
                if let localLease { try? await OfflineStore.shared.release(localLease) }
                return
            }
            await resolveAndLoad(track, generation: generation, resumeAt: resumeAt, autoAdvance: autoAdvance, localLease: localLease)
        }
        Task {
            await loadLyrics(for: track, generation: generation)
        }
    }

    private func resolveAndLoad(_ track: Track, generation: Int, resumeAt: TimeInterval = 0,
                                autoAdvance: Bool = false, localLease: OfflinePlaybackLease? = nil) async {
        let quality = SettingsManager.shared.audioQuality.rawValue
        // A logged-in account with no resolved profile has an unknown scope.
        // A missing or mismatched login snapshot must not expose another
        // account's downloads.
        let accountScope = offlineAccountScope
        var available = localLease
        if available == nil, let accountScope {
            available = try? await OfflineStore.shared.acquire(accountScope: accountScope, trackID: track.id,
                preferredQuality: quality, allowLowerQuality: !networkState.connected)
        }
        if let local = available {
            guard generation == resolveGeneration, accountScope == offlineAccountScope else {
                try? await OfflineStore.shared.release(local)
                return
            }
            consecutiveFailures = 0
            servedQuality = local.descriptor.identity.quality
            await loadPlaybackAsset(AVURLAsset(url: local.url), track: track, generation: generation,
                                    resolvedDuration: local.descriptor.duration, offlineLease: local, resumeAt: resumeAt)
            return
        }
        guard generation == resolveGeneration else { return }
        if usesOfflineQueue { unavailableOffline(track, generation: generation, autoAdvance: autoAdvance); return }
        var data: SongURLData?
        do {
            data = try await NeteaseAPI.songURL(ids: [track.id], level: quality).first
            if data?.url == nil, quality != AudioQuality.standard.rawValue {
                data = try await NeteaseAPI.songURL(ids: [track.id], level: AudioQuality.standard.rawValue).first
            }
        } catch {
            guard generation == resolveGeneration else { return }
            if Self.isConnectivityFailure(error) {
                if await playCachedFallback(track, generation: generation, scope: accountScope, quality: quality, resumeAt: resumeAt) { return }
                unavailableOffline(track, generation: generation, autoAdvance: autoAdvance)
                return
            }
        }
        guard generation == resolveGeneration else { return }

        var resolvedURL: URL?
        if let urlString = data?.url {
            resolvedURL = URL(string: urlString.replacingOccurrences(of: "http://", with: "https://"))
        }

        if resolvedURL == nil || data?.freeTrialInfo != nil {
            if await playCachedFallback(track, generation: generation, scope: accountScope, quality: quality, resumeAt: resumeAt) { return }
        }
        guard generation == resolveGeneration, accountScope == offlineAccountScope else { return }

        // NetEase refused — try third-party sources (UnblockNeteaseMusic-style).
        if resolvedURL == nil || data?.freeTrialInfo != nil, SettingsManager.shared.enableUnblock {
            if let unblocked = await UnblockService.resolve(track) {
                guard generation == resolveGeneration else { return }
                resolvedURL = unblocked.url
                unblockSource = unblocked.source
                data = nil
                ToastCenter.shared.show(String(localized: "已使用第三方音源：\(unblocked.source)"))
            }
        }
        guard generation == resolveGeneration else { return }

        guard let url = resolvedURL else {
            consecutiveFailures += 1
            let reason = track.playability(privilege: nil,
                                           isLoggedIn: AccountStore.shared.isLoggedIn,
                                           vipType: AccountStore.shared.vipType).reason
            ToastCenter.shared.show(String(localized: "《\(track.name)》无法播放\(reason.map { "：\($0)" } ?? "")"))
            guard isPlaying else {
                engine.replaceCurrentItem(with: nil)
                return
            }
            if consecutiveFailures < 5 {
                advanceToNext(userInitiated: false)
            } else {
                isPlaying = false
            }
            return
        }

        consecutiveFailures = 0
        servedQuality = data?.level
        if data?.freeTrialInfo != nil {
            isTrial = true
            ToastCenter.shared.show(String(localized: "VIP 歌曲，当前为试听片段"))
        }

        if let data, let accountScope, SettingsManager.shared.musicCachePolicy != .disabled,
           !DownloadManager.shared.pendingJobs.contains(where: { $0.accountScope == accountScope && $0.track.id == track.id }),
           let resource = await Self.resolveCacheResource(data: data, track: track, scope: accountScope) {
            guard generation == resolveGeneration, accountScope == offlineAccountScope else { return }
            let session = await PlaybackCacheController.shared.begin(resource: resource, fallbackURL: url) { [weak self] in
                Task { @MainActor in
                    guard let self, self.resolveGeneration == generation else { return }
                    self.stopAutomaticCaching()
                }
            }
            guard generation == resolveGeneration, accountScope == offlineAccountScope else {
                await session?.close()
                return
            }
            if let session {
                playbackCacheSession = session
                try? await OfflineMetadataStore.shared.save(track: track, scope: accountScope)
                guard generation == resolveGeneration, accountScope == offlineAccountScope else { return }
                cacheArtworkTask = Task { await OfflineMetadataStore.shared.fetchPlaybackArtwork(track: track, scope: accountScope) }
                await loadPlaybackAsset(session.loader.asset, track: track, generation: generation,
                                        resolvedDuration: resource.descriptor.duration, resumeAt: resumeAt)
                if generation == resolveGeneration { PlaybackCacheController.shared.startCompletion(for: session) }
                return
            }
        }

        guard generation == resolveGeneration, accountScope == offlineAccountScope else { return }

        await loadPlaybackAsset(AVURLAsset(url: url), track: track, generation: generation,
                                resolvedDuration: data.flatMap { $0.time > 0 ? Double($0.time) / 1000 : nil }, resumeAt: resumeAt)
    }

    private func playCachedFallback(_ track: Track, generation: Int, scope: String?, quality: String,
                                    resumeAt: TimeInterval) async -> Bool {
        guard generation == resolveGeneration, let scope, scope == offlineAccountScope,
              let local = try? await OfflineStore.shared.acquire(accountScope: scope, trackID: track.id, preferredQuality: quality) else { return false }
        guard generation == resolveGeneration, scope == offlineAccountScope else {
            try? await OfflineStore.shared.release(local)
            return false
        }
        consecutiveFailures = 0
        servedQuality = local.descriptor.identity.quality
        await loadPlaybackAsset(AVURLAsset(url: local.url), track: track, generation: generation,
                                resolvedDuration: local.descriptor.duration, offlineLease: local, resumeAt: resumeAt)
        return true
    }

    private static func resolveCacheResource(data: SongURLData, track: Track, scope: String) async -> OfflineAudioResource? {
        await withTaskGroup(of: OfflineAudioResource?.self) { group in
            group.addTask { try? await PlaybackCacheResolver.resolve(data: data, track: track, scope: scope) }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return nil }
            let resource = await group.next() ?? nil
            group.cancelAll()
            return resource
        }
    }

    /// Return to the ordinary stream while preserving queue, position and pause.
    /// The returned task releases the cache writer; playback reloads separately.
    @discardableResult
    func stopAutomaticCaching() -> Task<Void, Never>? {
        guard let session = playbackCacheSession, let track = currentTrack else { return nil }
        let position = engine.currentItem == nil ? progress : livePlaybackTime
        playbackCacheSession = nil
        resolveGeneration += 1
        let generation = resolveGeneration
        engine.replaceCurrentItem(with: nil)
        let stopped = PlaybackCacheController.shared.stop()
        Task {
            await stopped.value
            guard generation == resolveGeneration else { return }
            if let scope = offlineAccountScope,
               let local = try? await OfflineStore.shared.acquire(accountScope: scope, trackID: track.id,
                    preferredQuality: SettingsManager.shared.audioQuality.rawValue, allowLowerQuality: !networkState.connected) {
                guard generation == resolveGeneration, scope == offlineAccountScope else {
                    try? await OfflineStore.shared.release(local)
                    return
                }
                await loadPlaybackAsset(AVURLAsset(url: local.url), track: track, generation: generation,
                                        resolvedDuration: local.descriptor.duration, offlineLease: local, resumeAt: position)
                return
            }
            guard generation == resolveGeneration else { return }
            if usesOfflineQueue {
                unavailableOffline(track, generation: generation, autoAdvance: currentWasAdvanced && position < 0.5)
                return
            }
            await loadPlaybackAsset(AVURLAsset(url: session.fallbackURL), track: track, generation: generation,
                                    resolvedDuration: duration, resumeAt: position)
        }
        return stopped
    }

    private func loadPlaybackAsset(_ asset: AVURLAsset, track: Track, generation: Int,
                                   resolvedDuration: TimeInterval?, offlineLease: OfflinePlaybackLease? = nil,
                                   resumeAt: TimeInterval = 0) async {
        // Resolve the asset's audio track before the item goes live: an audio mix
        // attached after playback starts is silently ignored, so the spectrum tap
        // has to be spliced in here or not at all. Sources that refuse byte-range
        // requests never resolve a track — those play untapped and the UI falls
        // back to its decorative animation.
        let assetTrack = await loadAudioTrack(from: asset, timeout: 2)
        guard generation == resolveGeneration,
              offlineLease == nil || offlineLease?.descriptor.identity.accountScope == offlineAccountScope else {
            if let offlineLease { try? await OfflineStore.shared.release(offlineLease) }
            return
        }

        let item = AVPlayerItem(asset: asset)
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed, let error = item.error, Self.isConnectivityFailure(error) else { return }
            Task { @MainActor in
                guard let self, generation == self.resolveGeneration else { return }
                self.unavailableOffline(track, generation: generation,
                                        autoAdvance: self.currentWasAdvanced && self.progress < 0.5)
            }
        }
        if let assetTrack, let mix = AudioSpectrum.shared.makeAudioMix(for: assetTrack) {
            item.audioMix = mix
        } else {
            AudioSpectrum.shared.markUntappable()
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
        let previousLease = offlinePlaybackLease
        offlinePlaybackLease = offlineLease
        engine.replaceCurrentItem(with: item)
        if let previousLease {
            Task { try? await OfflineStore.shared.release(previousLease) }
        }
        if let resolvedDuration, resolvedDuration > 0 { duration = resolvedDuration }
        if resumeAt > 0 {
            let time = CMTime(seconds: min(resumeAt, max(0, duration - 0.1)), preferredTimescale: 600)
            _ = await engine.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            guard generation == resolveGeneration else { return }
        }
        if isPlaying {
            engine.play()
            scrobbleStartIfNeeded()
        }
        refreshPrefetchSoon()

        if let resolvedDuration, resolvedDuration > 0 {
            duration = resolvedDuration
            NowPlayingManager.shared.updateMetadata(for: track, duration: duration)
        }
        NowPlayingManager.shared.updateElapsed(progress, rate: isPlaying ? 1 : 0)
    }

    private var offlineAccountScope: String? {
        AccountStore.shared.offlineScope
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
        if let scope,
           let cached = await OfflineMetadataStore.shared.lyrics(trackID: track.id, scope: scope) {
            guard generation == resolveGeneration, offlineAccountScope == scope else { return }
            lyrics = LyricsParser.parse(cached)
            updateLyricsCursor(at: progress)
        }
        guard generation == resolveGeneration, offlineAccountScope == scope, !usesOfflineQueue else { return }
        let response = try? await NeteaseAPI.lyric(id: track.id)
        guard generation == resolveGeneration, offlineAccountScope == scope else { return }
        guard let response else { return }
        lyrics = LyricsParser.parse(response)
        if let scope { try? await OfflineMetadataStore.shared.save(lyrics: response, trackID: track.id, scope: scope) }
        updateLyricsCursor(at: progress)
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
        var rest = queue
        if let index = rest.firstIndex(where: { $0.id == first.id }) { rest.remove(at: index) }
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
        let scope = offlineAccountScope
        let generation = resolveGeneration
        Task {
            do {
                guard let resolved = try await resolve(context, reusingPlaybackQueue: true) else { return }
                guard scope == offlineAccountScope, generation == resolveGeneration else { return }
                play(tracks: resolved.tracks, source: resolved.source, context: context)
            } catch {
                guard scope == offlineAccountScope, generation == resolveGeneration else { return }
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    func resolve(_ context: PlayContext, reusingPlaybackQueue: Bool = false) async throws -> (tracks: [Track], source: PlaySource)? {
        let scope = offlineAccountScope
        if reusingPlaybackQueue, scope != nil, stateScope == scope, !isFMMode, context.source != .none,
           source == context.source, !queue.isEmpty {
            return (queue, source)
        }
        let downloads = DownloadManager.shared
        await downloads.start()
        guard scope == offlineAccountScope, downloads.accountScope == scope else { throw CancellationError() }
        if context.kind == .playlist, let scope,
           let saved = await PlaylistSnapshotStore.shared.load(id: context.id, scope: scope) {
            guard scope == offlineAccountScope else { throw CancellationError() }
            if saved.isComplete || usesOfflineQueue, !saved.detail.tracks.isEmpty || saved.isComplete {
                return (saved.detail.tracks, .playlist(context.id))
            }
        }
        let liked = context.kind == .playlist && AccountStore.shared.likedSongsPlaylist?.id == context.id
            ? AccountStore.shared.likedTrackIDs : []
        let local = downloads.localTracks(for: context, likedTrackIDs: liked)
        let saved = context.downloadCollectionID.map { id in downloads.collections.contains { $0.id == id } } ?? false
        if !local.isEmpty, saved || usesOfflineQueue { return (local, context.source) }
        if usesOfflineQueue { throw URLError(.notConnectedToInternet) }
        do {
            let resolved = try await resolveOnline(context)
            guard scope == offlineAccountScope else { throw CancellationError() }
            return resolved
        } catch {
            guard scope == offlineAccountScope, !Task.isCancelled else { throw CancellationError() }
            if !local.isEmpty { return (local, context.source) }
            throw error
        }
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
            let model = PlaylistContent(playlistID: context.id)
            await model.load()
            guard model.detail != nil, !model.tracks.isEmpty || model.detail?.trackCount == 0 else {
                throw URLError(.cannotLoadFromNetwork)
            }
            return (model.tracks, .playlist(context.id))
        }
    }

    private func persistState() {
        queueRevision += 1
        refreshPrefetchSoon()
        guard let scope = stateScope else { return }
        guard sessionSnapshotDirty else { checkpointPosition(); return }
        sessionSnapshotDirty = false
        sessionID = UUID()
        persistenceRevision += 1
        let revision = persistenceRevision
        let snapshot = PlaybackSessionSnapshot(sessionID: sessionID, accountScope: scope, queue: queue,
            shuffledQueue: shuffledQueue, playNextList: playNextList, fmUpcoming: fmUpcoming,
            currentIndex: currentIndex, currentTrack: currentTrack, progress: progress, source: source,
            repeatMode: repeatMode.rawValue, shuffle: shuffleEnabled, isFM: isFMMode, recentContexts: recentContexts)
        Task { try? await PlaybackSessionStore.shared.save(snapshot, revision: revision) }
    }

    private func restoreState() {
        guard let scope = stateScope, let state = PlaybackSessionStore.shared.load(scope: scope) else { return }
        isRestoringState = true
        defer { isRestoringState = false; sessionSnapshotDirty = false }
        sessionID = state.sessionID
        recentContexts = Array(state.recentContexts.prefix(Self.recentContextsLimit))
        queue = state.queue
        shuffleEnabled = state.shuffle
        shuffledQueue = state.shuffledQueue
        playNextList = state.playNextList
        fmUpcoming = state.fmUpcoming
        isFMMode = state.isFM
        source = state.source
        repeatMode = RepeatMode(rawValue: state.repeatMode) ?? .off
        currentIndex = activeQueue.indices.contains(state.currentIndex) ? state.currentIndex : -1
        currentTrack = state.currentTrack
        PlaybackCacheController.shared.protect(trackID: currentTrack?.id, scope: stateScope)
        progress = state.progress
        lastCheckpoint = progress
        isPlaying = false
        if let track = currentTrack {
            duration = track.duration
            NowPlayingManager.shared.updateMetadata(for: track, duration: duration)
            NowPlayingManager.shared.updateElapsed(progress, rate: 0)
            let generation = resolveGeneration
            Task { await loadLyrics(for: track, generation: generation) }
        }
    }

    func checkpointPosition() {
        guard let scope = stateScope, let track = currentTrack else { return }
        persistenceRevision += 1
        let revision = persistenceRevision
        lastCheckpoint = progress
        let position = PlaybackPositionSnapshot(sessionID: sessionID, trackID: track.id, progress: progress,
                                                currentIndex: currentIndex, currentTrack: track)
        Task { try? await PlaybackSessionStore.shared.savePosition(position, scope: scope, revision: revision) }
    }

    func activateAccount(scope: String?) {
        guard stateScope != scope else { return }
        persistState()
        resolveGeneration += 1
        offlineScan?.cancel()
        offlineScan = nil
        offlineScanID = UUID()
        offlineIssue = nil
        engine.replaceCurrentItem(with: nil)
        playbackCacheSession = nil
        cacheArtworkTask?.cancel()
        PlaybackCacheController.shared.protect(trackID: nil, scope: nil)
        PlaybackCacheController.shared.stop()
        if let lease = offlinePlaybackLease {
            offlinePlaybackLease = nil
            Task { try? await OfflineStore.shared.release(lease) }
        }
        isPlaying = false
        currentTrack = nil
        queue = []; shuffledQueue = []; playNextList = []; fmUpcoming = []; recentContexts = []
        currentIndex = -1
        progress = 0
        duration = 0
        lyrics = nil
        isFMMode = false
        shuffleEnabled = false
        source = .none
        servedQuality = nil
        unblockSource = nil
        isTrial = false
        showNowPlaying = false
        stateScope = scope
        AudioSpectrum.shared.markIdle()
        NowPlayingManager.shared.clear()
        restoreState()
    }
}
