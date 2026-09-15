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
    /// Passthrough to the clock so existing `progress` reads/writes keep working.
    var progress: TimeInterval {
        get { clock.progress }
        set { clock.progress = newValue }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet {
            UserDefaults.standard.set(repeatMode.rawValue, forKey: "player.repeat")
            if !isRestoringState { persistState() }
        }
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
    private var offlinePlaybackLease: OfflinePlaybackLease?
    private var stateScope: String?
    private var sessionID = UUID()
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
                }
            }
        }

        statusObservation = engine.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }

        NowPlayingManager.shared.attach(to: self)
        stateScope = AccountStore.shared.offlineScope
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
            // Restored session: re-resolve the source.
            startPlaying(track, indexUnchanged: true, resumeAt: progress)
            return
        } else {
            engine.play()
            isPlaying = true
        }
        NowPlayingManager.shared.updateElapsed(progress, rate: isPlaying ? 1 : 0)
        checkpointPosition()
    }

    func pause() {
        engine.pause()
        isPlaying = false
        AudioSpectrum.shared.reset()
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
        checkpointPosition()
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
        checkpointPosition()
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
        defer { persistState() }
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
                persistState()
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
            seek(to: 0)
            engine.play()
            isPlaying = true
            return
        }
        advanceToNext(userInitiated: false)
    }

    // MARK: - Source resolution

    private func startPlaying(_ track: Track, indexUnchanged: Bool = false, resumeAt: TimeInterval = 0) {
        scrobbleIfNeeded(completed: false)
        engine.replaceCurrentItem(with: nil)
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
            await resolveAndLoad(track, generation: generation, resumeAt: resumeAt)
        }
        Task {
            await loadLyrics(for: track, generation: generation)
        }
    }

    private func resolveAndLoad(_ track: Track, generation: Int, resumeAt: TimeInterval = 0) async {
        let quality = SettingsManager.shared.audioQuality.rawValue
        // A logged-in account with no resolved profile has an unknown scope.
        // A missing or mismatched login snapshot must not expose another
        // account's downloads.
        let accountScope = offlineAccountScope
        if let accountScope,
           let local = try? await OfflineStore.shared.acquire(accountScope: accountScope, trackID: track.id, preferredQuality: quality) {
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
        var data = try? await NeteaseAPI.songURL(ids: [track.id], level: quality).first
        if data?.url == nil, quality != AudioQuality.standard.rawValue {
            data = try? await NeteaseAPI.songURL(ids: [track.id], level: AudioQuality.standard.rawValue).first
        }
        guard generation == resolveGeneration else { return }

        var resolvedURL: URL?
        if let urlString = data?.url {
            resolvedURL = URL(string: urlString.replacingOccurrences(of: "http://", with: "https://"))
        }

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

        await loadPlaybackAsset(AVURLAsset(url: url), track: track, generation: generation,
                                resolvedDuration: data.flatMap { $0.time > 0 ? Double($0.time) / 1000 : nil }, resumeAt: resumeAt)
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
        if isPlaying { engine.play() }

        if !startScrobbled {
            startScrobbled = true
            let tid = track.id
            let sid = source.sourceID
            Task.detached { await NeteaseAPI.scrobbleStart(trackID: tid, sourceID: sid) }
        }

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
        if let scope = offlineAccountScope,
           let cached = await OfflineMetadataStore.shared.lyrics(trackID: track.id, scope: scope) {
            guard generation == resolveGeneration, offlineAccountScope == scope else { return }
            lyrics = LyricsParser.parse(cached)
            updateLyricsCursor(at: progress)
            return
        }
        let scope = offlineAccountScope
        let response = try? await NeteaseAPI.lyric(id: track.id)
        guard generation == resolveGeneration, offlineAccountScope == scope else { return }
        lyrics = response.map(LyricsParser.parse)
        if let response, let scope { try? await OfflineMetadataStore.shared.save(lyrics: response, trackID: track.id, scope: scope) }
        updateLyricsCursor(at: progress)
    }

    // MARK: - Scrobble

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

    private func persistState() {
        guard let scope = stateScope else { return }
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
        defer { isRestoringState = false }
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
        let position = PlaybackPositionSnapshot(sessionID: sessionID, trackID: track.id, progress: progress)
        Task { try? await PlaybackSessionStore.shared.savePosition(position, scope: scope, revision: revision) }
    }

    func activateAccount(scope: String?) {
        guard stateScope != scope else { return }
        persistState()
        resolveGeneration += 1
        engine.replaceCurrentItem(with: nil)
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
