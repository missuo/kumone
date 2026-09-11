import SwiftUI

enum TrackRowStyle {
    /// Artwork + album column (playlists, search, daily).
    case full
    /// Track number, no artwork (album pages).
    case albumTrack
    /// Compact with artwork, no album column (artist hot songs, panels).
    case compact
}

enum RecommendationContext {
    case daily
    case radar
}

// MARK: - Row

struct TrackRow: View {
    let track: Track
    let index: Int
    var style: TrackRowStyle = .full
    var playability: TrackPlayability = .playable
    /// Extra trailing text (e.g. play count for recents).
    var trailingText: String?
    /// Set when the row lives inside a user's own playlist (enables 删除).
    var removableFromPlaylistID: Int?
    var onRemoved: (() -> Void)?
    var onRecommendationReduced: ((Track) -> Void)?
    let onPlay: () -> Void

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openDestination) private var openDestination
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ScaledMetric(relativeTo: .body) private var compactArtworkSize: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var compactRowHeight: CGFloat = 64
    @ScaledMetric(relativeTo: .body) private var compactAlbumRowHeight: CGFloat = 50
    @State private var isHovering = false
    @State private var showAddToPlaylist = false
    @State private var isReducingRecommendation = false

    private var isCurrent: Bool { player.currentTrack?.id == track.id }
    private var isPlayable: Bool { playability == .playable }
    private var showsArtwork: Bool { style != .albumTrack }

    private var hidesLeadingIndex: Bool {
        #if os(iOS)
        return isCompact && showsArtwork
        #else
        return false
        #endif
    }

    private var isCompact: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        HStack(spacing: 12) {
            if !hidesLeadingIndex {
                leadingIndicator
            }

            if showsArtwork {
                artwork
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(track.name)
                        .font(isCompact ? .callout.weight(.medium) : .system(size: 13, weight: .medium))
                        .foregroundStyle(isCurrent ? Theme.accent : .primary)
                        .lineLimit(1)
                    if let subtitle = track.subtitle, !isCompact {
                        Text("(\(subtitle))")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if track.fee == 1 {
                        VIPBadge()
                    }
                }
                artistLinks
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if style == .full && !isCompact {
                if track.album.id > 0, !track.album.name.isEmpty {
                    Button {
                        openDestination(.album(track.album.id))
                    } label: {
                        Text(track.album.name)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开专辑：\(track.album.name)")
                    .frame(maxWidth: 220, alignment: .leading)
                } else {
                    Text(track.album.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .leading)
                }
            }

            if let reason = playability.reason {
                Text(reason)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
            }

            if let trailingText {
                Text(trailingText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            likeAndDuration
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isCompact ? 6 : 5)
        // Fixed row height keeps lazy-stack height estimation exact,
        // preventing scroll-offset jumps in long lists (#3).
        .frame(height: rowHeight)
        .opacity(isPlayable ? 1 : 0.45)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(AppAnimation.quick) { isHovering = hovering }
        }
        #if os(macOS)
        .onTapGesture(count: 2) {
            if isPlayable { onPlay() }
        }
        #else
        .onTapGesture {
            if isPlayable { onPlay() }
        }
        #endif
        .contextMenu { contextMenuItems }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistSheet(track: track)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if track.album.id > 0, !track.album.name.isEmpty {
            Button {
                openDestination(.album(track.album.id))
            } label: {
                artworkImage
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开专辑：\(track.album.name)")
        } else {
            artworkImage
        }
    }

    @ViewBuilder
    private var artworkImage: some View {
        if isCompact {
            CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(160), animated: false)
                .frame(width: compactArtworkSize, height: compactArtworkSize)
                .overlay(alignment: .bottomTrailing) {
                    if hidesLeadingIndex, isCurrent {
                        PlayingIndicator(animating: player.isPlaying && !player.showNowPlaying)
                            .padding(5)
                            .background(
                                .ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .padding(4)
                    }
                }
                .compositingGroup()
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        } else {
            CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(96), animated: false)
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
    }

    @ViewBuilder
    private var artistLinks: some View {
        let artists = track.artists.filter { $0.id > 0 && !$0.name.isEmpty }
        if artists.isEmpty {
            Text(track.artistNames)
                .font(isCompact ? .footnote : .system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                    if index > 0 {
                        Text(" / ")
                    }
                    Button {
                        openDestination(.artist(artist.id))
                    } label: {
                        Text(artist.name)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开歌手：\(artist.name)")
                }
            }
            .font(isCompact ? .footnote : .system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var rowHeight: CGFloat {
        if style == .albumTrack {
            return isCompact ? compactAlbumRowHeight : 46
        }
        return isCompact ? compactRowHeight : 52
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        ZStack {
            if isCurrent {
                PlayingIndicator(animating: player.isPlaying && !player.showNowPlaying)
            } else if isHovering, isPlayable {
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.pressable)
            } else {
                Text(String(index))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 28)
    }

    private var likeAndDuration: some View {
        HStack(spacing: 8) {
            let liked = account.isLiked(track.id)
            Button {
                Task { await account.toggleLike(trackID: track.id) }
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 12))
                    .foregroundStyle(liked ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.pressable)
            .opacity(liked || isHovering ? 1 : 0)

            Text(Formatters.duration(track.duration))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("播放") { onPlay() }
        Button("下一首播放") {
            player.addToPlayNext(track)
        }
        Divider()
        let liked = account.isLiked(track.id)
        Button(liked ? String(localized: "从「我喜欢」中移除") : String(localized: "添加到「我喜欢」")) {
            Task { await account.toggleLike(trackID: track.id) }
        }
        Button("收藏到歌单…") {
            showAddToPlaylist = true
        }
        if let pid = removableFromPlaylistID {
            Button("从歌单中删除", role: .destructive) {
                Task {
                    do {
                        try await NeteaseAPI.playlistTracks(op: "del", playlistID: pid, trackIDs: [track.id])
                        onRemoved?()
                        ToastCenter.shared.show(String(localized: "已从歌单中删除"))
                    } catch {
                        ToastCenter.shared.show(error.localizedDescription)
                    }
                }
            }
        }
        #if os(macOS)
        if !account.isLiked(track.id), let onRecommendationReduced {
            Button(String(localized: "减少推荐"), role: .destructive) {
                guard !isReducingRecommendation else { return }
                isReducingRecommendation = true
                Task {
                    defer { isReducingRecommendation = false }
                    do {
                        let replacement = try await NeteaseAPI.dislikeRecommendedSong(id: track.id)
                        onRecommendationReduced(replacement)
                        ToastCenter.shared.show(String(localized: "已减少推荐"))
                    } catch {
                        ToastCenter.shared.show(error.localizedDescription)
                    }
                }
            }
            .disabled(isReducingRecommendation)
        }
        #endif
        Divider()
        if track.album.id > 0 {
            NavigationLink(value: Destination.album(track.album.id)) {
                Text("查看专辑")
            }
        }
        ForEach(track.artists.prefix(3)) { artist in
            NavigationLink(value: Destination.artist(artist.id)) {
                Text("查看歌手：\(artist.name)")
            }
        }
        Divider()
        Button("复制链接") {
            Platform.copyToPasteboard(string: "https://music.163.com/#/song?id=\(track.id)")
            ToastCenter.shared.show(String(localized: "链接已复制"))
        }
    }
}

// MARK: - Playing indicator

/// The four bars beside the row that's playing.
///
/// Deliberately not a SwiftUI animation. Driving these from `TimelineView` —
/// as this did for a long time — makes SwiftUI re-evaluate and re-lay-out the
/// enclosing tree on every tick, and with the now-playing page presented as an
/// overlay that tree is the entire window. Profiling put the cost at roughly
/// 30% of a core, for four 14pt bars.
///
/// Scaling plain `CALayer`s instead is a compositing change: no `draw`, no
/// layout invalidation, nothing above it in the tree ever learns a frame
/// happened.
struct PlayingIndicator: View {
    var animating: Bool

    var body: some View {
        SpectrumBars(animating: animating)
            .frame(width: SpectrumBarsView.width, height: SpectrumBarsView.maxHeight)
    }
}

#if os(macOS)
private struct SpectrumBars: NSViewRepresentable {
    var animating: Bool
    func makeNSView(context: Context) -> SpectrumBarsView { SpectrumBarsView() }
    func updateNSView(_ view: SpectrumBarsView, context: Context) {
        view.animating = animating
    }
    static func dismantleNSView(_ view: SpectrumBarsView, coordinator: ()) {
        view.animating = false
    }
}
#else
private struct SpectrumBars: UIViewRepresentable {
    var animating: Bool
    func makeUIView(context: Context) -> SpectrumBarsView { SpectrumBarsView() }
    func updateUIView(_ view: SpectrumBarsView, context: Context) {
        view.animating = animating
    }
    static func dismantleUIView(_ view: SpectrumBarsView, coordinator: ()) {
        view.animating = false
    }
}
#endif

final class SpectrumBarsView: PlatformView {
    static let minHeight: CGFloat = 3
    static let maxHeight: CGFloat = 14
    static let barWidth: CGFloat = 2.5
    static let spacing: CGFloat = 2
    static let width =
        CGFloat(AudioSpectrum.bandCount) * barWidth
        + CGFloat(AudioSpectrum.bandCount - 1) * spacing

    private var bars: [CALayer] = []
    private var timer: Timer?
    private var startedAt = CACurrentMediaTime()

    var animating = false {
        didSet {
            guard animating != oldValue else { return }
            animating ? start() : stop()
        }
    }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.maxHeight))
        #if os(macOS)
        wantsLayer = true
        #endif
        buildBars()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { timer?.invalidate() }

    /// `NSView.layer` is optional; `UIView.layer` is not.
    private var hostLayer: CALayer? { layer }

    private func buildBars() {
        guard let host = hostLayer else { return }
        let color = PlatformColor(Theme.accent).cgColor
        for _ in 0..<AudioSpectrum.bandCount {
            let bar = CALayer()
            bar.backgroundColor = color
            bar.cornerRadius = 1
            // Centered anchor so a scale grows the bar symmetrically.
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: Self.maxHeight)
            host.addSublayer(bar)
            bars.append(bar)
        }
        apply(scaleForAll: Self.minHeight / Self.maxHeight)
    }

    #if os(macOS)
    override func layout() {
        super.layout()
        positionBars()
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        positionBars()
    }
    #endif

    private func positionBars() {
        for (i, bar) in bars.enumerated() {
            bar.position = CGPoint(
                x: CGFloat(i) * (Self.barWidth + Self.spacing) + Self.barWidth / 2,
                y: bounds.midY)
        }
    }

    private func start() {
        guard timer == nil else { return }
        startedAt = CACurrentMediaTime()
        // Common mode so the bars keep moving while a list is being scrolled.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        apply(scaleForAll: Self.minHeight / Self.maxHeight)
    }

    @MainActor
    private func tick() {
        let spectrum = AudioSpectrum.shared
        let live: Bool
        switch spectrum.tapState {
        case .tapped:
            // Samples may still be a few hundred milliseconds out while the
            // source buffers. Hold still through that rather than animating,
            // which reads as a glitch right as a song starts.
            live = spectrum.isLive
            guard live else {
                apply(scaleForAll: Self.minHeight / Self.maxHeight)
                return
            }
        case .untappable:
            live = false
        case .idle, .preparing:
            // Not yet known whether this source can be tapped.
            apply(scaleForAll: Self.minHeight / Self.maxHeight)
            return
        }

        let elapsed = CACurrentMediaTime() - startedAt
        let span = Self.maxHeight - Self.minHeight

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            // Real band levels when the tap is feeding us; otherwise the old
            // decorative sine, so untappable sources still look alive.
            let level = live
                ? CGFloat(spectrum.level(at: i))
                : CGFloat(abs(sin(elapsed * 2.4 + Double(i) * 0.9)))
            let height = Self.minHeight + span * level
            bar.transform = CATransform3DMakeScale(1, height / Self.maxHeight, 1)
        }
        CATransaction.commit()
    }

    private func apply(scaleForAll scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            bar.transform = CATransform3DMakeScale(1, scale, 1)
        }
        CATransaction.commit()
    }
}

// MARK: - Track list

struct TrackListView: View {
    let tracks: [Track]
    var style: TrackRowStyle = .full
    var privileges: [Int: TrackPrivilege] = [:]
    var source: PlaySource = .none
    /// The place this list belongs to, for the Dock menu's recents.
    var context: PlayContext?
    var removableFromPlaylistID: Int?
    var onRemoved: ((Track) -> Void)?
    var recommendationContext: RecommendationContext?
    var onRecommendationReduced: ((Track, Track) -> Void)?

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        LazyVStack(spacing: 1) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                let recommendationHandler = onRecommendationReduced
                TrackRow(
                    track: track,
                    index: style == .albumTrack ? (track.trackNo > 0 ? track.trackNo : index + 1) : index + 1,
                    style: style,
                    playability: playability(of: track),
                    removableFromPlaylistID: removableFromPlaylistID,
                    onRemoved: { onRemoved?(track) },
                    onRecommendationReduced: recommendationContext == nil || recommendationHandler == nil
                        ? nil
                        : { replacement in recommendationHandler?(track, replacement) }
                ) {
                    player.play(tracks: playableTracks, source: source, startAt: track,
                                context: context)
                }
            }
        }
    }

    private var playableTracks: [Track] {
        tracks.filter { playability(of: $0) == .playable }
    }

    private func playability(of track: Track) -> TrackPlayability {
        // With unblock enabled, gray tracks resolve from third-party sources.
        if SettingsManager.shared.enableUnblock { return .playable }
        return track.playability(
            privilege: privileges[track.id],
            isLoggedIn: account.isLoggedIn,
            vipType: account.vipType
        )
    }
}

// MARK: - Add to playlist

struct AddToPlaylistSheet: View {
    let track: Track

    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("收藏到歌单")
                .font(.headline)
                .padding(16)
            Divider().opacity(0.4)
            if account.createdPlaylists.isEmpty {
                EmptyStateView(icon: "music.note.list", title: "还没有创建歌单")
                    .frame(height: 200)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(account.createdPlaylists) { playlist in
                            Button {
                                add(to: playlist)
                            } label: {
                                HStack(spacing: 10) {
                                    CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(80), animated: false)
                                        .frame(width: 36, height: 36)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text("\(playlist.trackCount) 首")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.interactiveRow)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 280)
            }
            Divider().opacity(0.4)
            HStack {
                TextField("新建歌单", text: $newName)
                    .textFieldStyle(.roundedBorder)
                Button("创建并收藏") {
                    createAndAdd()
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || creating)
            }
            .padding(12)
        }
        .frame(width: 340)
    }

    private func add(to playlist: PlaylistSummary) {
        Task {
            do {
                try await NeteaseAPI.playlistTracks(op: "add", playlistID: playlist.id, trackIDs: [track.id])
                ToastCenter.shared.show(String(localized: "已收藏到「\(playlist.name)」"))
                await account.refreshLibrary()
                dismiss()
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private func createAndAdd() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        creating = true
        Task {
            defer { creating = false }
            do {
                if let id = try await NeteaseAPI.createPlaylist(name: name, isPrivate: false) {
                    try await NeteaseAPI.playlistTracks(op: "add", playlistID: id, trackIDs: [track.id])
                    ToastCenter.shared.show(String(localized: "已收藏到「\(name)」"))
                    await account.refreshLibrary()
                    dismiss()
                }
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }
}
