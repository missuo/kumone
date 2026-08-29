import SwiftUI

/// Immersive full-window now-playing page: artwork-tinted gradient backdrop,
/// large artwork on the left, big synced lyrics on the right.
struct NowPlayingView: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager
    #if os(iOS)
    @Environment(\.dismissNowPlayingAction) private var dismissNowPlayingAction
    @Environment(\.dismissNowPlayingDragAction) private var dismissNowPlayingDragAction
    #endif

    @State private var artworkImage: PlatformImage?
    @State private var colors: ArtworkColors = .fallback
    @State private var activeIndex: Int?
    @State private var isUserScrolling = false
    @State private var resumeTask: Task<Void, Never>?
    @State private var showLyricsOnMobile = false
    #if os(iOS)
    @State private var showQueueOnMobile = false
    #endif

    var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < 720
            ZStack {
                backdrop

                if isCompact {
                    compactLayout(size: geo.size)
                } else {
                    regularLayout(size: geo.size)
                }
            }
            // Pin to the screen width so an intrinsically-wide child can never
            // stretch the ZStack and push the corner overlays off-screen.
            .frame(width: geo.size.width)
            .overlay(alignment: .topLeading) {
                if showsClassicChrome(isCompact: isCompact) {
                    Button {
                        close()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.pressable)
                    .padding(.top, 20)
                    .padding(.leading, 20)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isCompact, showsClassicChrome(isCompact: isCompact) {
                    Button {
                        withAnimation(AppAnimation.standard) {
                            showLyricsOnMobile.toggle()
                        }
                    } label: {
                        Image(systemName: showLyricsOnMobile ? "music.note" : "quote.bubble")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(showLyricsOnMobile ? Theme.accent : .white.opacity(0.85))
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.pressable)
                    .padding(.top, 20)
                    .padding(.trailing, 20)
                }
            }
            #if os(iOS)
            .overlay {
                if settings.nowPlayingMode == .minimal && showQueueOnMobile {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showQueueOnMobile = false }
                        .accessibilityLabel("关闭播放列表")
                        .accessibilityAddTraits(.isButton)
                }
            }
            #endif
        }
        #if os(macOS)
        // The window toolbar is hidden while this page is up, but SwiftUI keeps
        // reserving its safe area, which pushed the whole immersive layout —
        // close button included — a toolbar's height down from the window top.
        // iOS keeps its safe area: there the inset is the status bar / notch.
        .ignoresSafeArea()
        #endif
        .preferredColorScheme(.dark)
        .task(id: player.currentTrack?.id) {
            await loadArtwork()
        }
        #if os(iOS)
        .onAppear {
            showLyricsOnMobile = settings.nowPlayingMode == .immersive
            showQueueOnMobile = false
        }
        .onChange(of: settings.nowPlayingMode) { _ in
            showLyricsOnMobile = settings.nowPlayingMode == .immersive
            showQueueOnMobile = false
        }
        .onChange(of: player.currentTrack?.id) { _ in
            if settings.nowPlayingMode == .minimal {
                showLyricsOnMobile = false
            }
        }
        #endif
        #if os(macOS)
        .onExitCommand {
            close()
        }
        #endif
    }

    private var hasLyricsColumn: Bool {
        if let lyrics = player.lyrics, !lyrics.isEmpty { return true }
        return player.lyrics == nil // still loading — keep layout stable
    }

    private func close() {
        #if os(iOS)
        if let dismissNowPlayingAction {
            dismissNowPlayingAction()
        } else {
            withAnimation(NowPlayingPresentationMetrics.presentationAnimation) {
                player.showNowPlaying = false
            }
        }
        #else
        player.showNowPlaying = false
        #endif
    }

    private func showsClassicChrome(isCompact: Bool) -> Bool {
        #if os(iOS)
        return !isCompact || settings.nowPlayingMode == .classic
        #else
        return true
        #endif
    }


    /// Jump straight to the line the song is on. Used when the view appears,
    /// where waiting for the next line change would leave the lyrics parked at
    /// the top. Scrolling is deferred a turn: the list has not laid out yet
    /// while `onAppear` runs, and `scrollTo` on an unlaid list does nothing.
    private func adoptCursor(proxy: ScrollViewProxy) {
        let index = lyricsCursor.activeIndex
        activeIndex = index
        guard let index else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: [colors.primary, colors.secondary],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [.white.opacity(0.12), .clear],
                center: .topLeading, startRadius: 0, endRadius: 700
            )
            LinearGradient(
                colors: [.clear, .black.opacity(0.35)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: colors)
    }

    private func loadArtwork() async {
        guard let urlString = player.currentTrack?.album.picUrl,
              let url = urlString.resizedImageURL(768) else {
            artworkImage = nil
            colors = .fallback
            return
        }
        if let image = await ImageCache.shared.image(for: url) {
            artworkImage = image
            colors = ArtworkPalette.extract(from: image, cacheKey: urlString)
        }
    }

    // MARK: - Layouts

    private func regularLayout(size: CGSize) -> some View {
        // Everything below the artwork needs ~300pt; shrink the artwork on
        // short displays (iPhone landscape) instead of clipping it.
        let artworkSize = max(120, min(340, size.width * 0.32, size.height - 300))
        return HStack(spacing: 0) {
            leftColumn(artworkSize: artworkSize)
                .frame(maxWidth: .infinity)
            if hasLyricsColumn {
                lyricsColumn
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, size.height < 500 ? 24 : 40)
    }

    @ViewBuilder
    private func compactLayout(size: CGSize) -> some View {
        #if os(iOS)
        switch settings.nowPlayingMode {
        case .classic:
            classicCompactLayout(size: size)
        case .immersive:
            immersiveCompactLayout(size: size)
        case .minimal:
            minimalCompactLayout(size: size)
        }
        #else
        classicCompactLayout(size: size)
        #endif
    }

    private func classicCompactLayout(size: CGSize) -> some View {
        let artworkDim = min(size.width - 64, size.height * 0.38, 300)
        return VStack(spacing: 20) {
            Spacer().frame(height: 44)
            if showLyricsOnMobile {
                lyricsColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                VStack(spacing: 20) {
                    artworkView(size: artworkDim)
                    trackMetaView
                    MiniLyricsView {
                        withAnimation(AppAnimation.standard) {
                            showLyricsOnMobile = true
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.opacity)
            }
            VStack(spacing: 12) {
                NowPlayingScrubber()
                    .padding(.horizontal, 24)
                controls
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 16)
    }

    #if os(iOS)
    private func immersiveCompactLayout(size: CGSize) -> some View {
        let artworkDimension = min(size.width - 112, size.height * 0.3, 250)
        let showsExpandedArtwork = !showLyricsOnMobile && !showQueueOnMobile

        return VStack(spacing: 0) {
            Color.clear.frame(
                height: NowPlayingPresentationMetrics.immersiveHeaderTopInset
            )

            CompactTrackHeader(showsExpandedArtwork: showsExpandedArtwork)
                .padding(.bottom, 14)

            ZStack {
                immersiveArtworkContent(artworkDimension: artworkDimension)
                    .opacity(showsExpandedArtwork ? 1 : 0)
                    .allowsHitTesting(showsExpandedArtwork)
                    .accessibilityHidden(!showsExpandedArtwork)

                if showQueueOnMobile {
                    CompactQueueContent()
                        .transition(.opacity)
                } else {
                    IOSImmersiveLyricsColumn()
                        .opacity(showLyricsOnMobile ? 1 : 0)
                        .allowsHitTesting(showLyricsOnMobile)
                        .accessibilityHidden(!showLyricsOnMobile)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            immersiveControls
        }
        .frame(width: max(size.width - 64, 0))
        .padding(.horizontal, 32)
        .overlayPreferenceValue(ImmersiveArtworkFramePreferenceKey.self) { frames in
            GeometryReader { proxy in
                if let compactAnchor = frames[.compact],
                   let expandedAnchor = frames[.expanded] {
                    let compactFrame = proxy[compactAnchor]
                    let expandedFrame = proxy[expandedAnchor]
                    let targetFrame = showsExpandedArtwork ? expandedFrame : compactFrame
                    let targetCenterX = showsExpandedArtwork
                        ? size.width / 2
                        : compactFrame.midX

                    immersiveArtworkSurface(isExpanded: showsExpandedArtwork)
                        .frame(width: targetFrame.width, height: targetFrame.height)
                        .position(x: targetCenterX, y: targetFrame.midY)
                        .accessibilityIdentifier("immersiveArtwork")
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var immersiveControls: some View {
        VStack(spacing: 17) {
            NowPlayingScrubber()
            CompactTransportControls()
            CompactVolumeControl()
            CompactSecondaryControls(
                showsLyrics: showLyricsOnMobile,
                showsQueue: showQueueOnMobile,
                onToggleLyrics: toggleImmersiveLyrics,
                onToggleQueue: toggleImmersiveQueue
            )
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .accessibilityIdentifier("immersiveControls")
    }

    private func immersiveArtworkContent(artworkDimension: CGFloat) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            Color.clear
                .frame(width: artworkDimension, height: artworkDimension)
                .anchorPreference(
                    key: ImmersiveArtworkFramePreferenceKey.self,
                    value: .bounds
                ) { [.expanded: $0] }
            MiniLyricsView(onOpen: showImmersiveLyrics)
                .frame(maxWidth: .infinity, maxHeight: 96)
            Spacer(minLength: 0)
        }
    }

    private func immersiveArtworkSurface(isExpanded: Bool) -> some View {
        Group {
            if let artworkImage {
                Image(platformImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.white.opacity(isExpanded ? 0.06 : 0.1))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: isExpanded ? 48 : 18, weight: .light))
                            .foregroundStyle(.white.opacity(isExpanded ? 0.3 : 0.45))
                    }
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: isExpanded ? 18 : 12,
                style: .continuous
            )
        )
        .shadow(
            color: .black.opacity(isExpanded ? 0.45 : 0.22),
            radius: isExpanded ? 36 : 10,
            y: isExpanded ? 18 : 4
        )
    }

    private func toggleImmersiveLyrics() {
        withAnimation(ImmersiveArtworkTransition.animation) {
            if showQueueOnMobile {
                showQueueOnMobile = false
                showLyricsOnMobile = true
            } else {
                showLyricsOnMobile.toggle()
            }
        }
    }

    private func showImmersiveLyrics() {
        withAnimation(ImmersiveArtworkTransition.animation) {
            showQueueOnMobile = false
            showLyricsOnMobile = true
        }
    }

    private func toggleImmersiveQueue() {
        withAnimation(ImmersiveArtworkTransition.animation) {
            showQueueOnMobile.toggle()
        }
    }

    private func minimalCompactLayout(size: CGSize) -> some View {
        let contentWidth = max(size.width - 64, 0)
        let artworkDimension = min(contentWidth, size.height * 0.52, 378)

        return VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Color.clear
                MinimalTrackInfoRow(metadataOnly: true)
                    .padding(.top, NowPlayingPresentationMetrics.immersiveHeaderTopInset)
                    .opacity(showLyricsOnMobile ? 1 : 0)
                    .accessibilityHidden(!showLyricsOnMobile)
            }
            .frame(height: 90)

            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggleMinimalLyrics)

                artworkView(size: artworkDimension)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggleMinimalLyrics)
                    .accessibilityIdentifier("immersiveArtwork")
                    .accessibilityLabel("显示歌词")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { toggleMinimalLyrics() }
                    .opacity(showLyricsOnMobile ? 0 : 1)
                    .allowsHitTesting(!showLyricsOnMobile)

                IOSMinimalLyricsColumn {
                    showLyricsOnMobile = false
                }
                .opacity(showLyricsOnMobile ? 1 : 0)
                .allowsHitTesting(showLyricsOnMobile)
                .accessibilityHidden(!showLyricsOnMobile)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .simultaneousGesture(
                minimalDismissGesture,
                including: showLyricsOnMobile ? .none : .all
            )
            .padding(.bottom, 20)

            minimalControls
        }
        .frame(width: contentWidth)
        .padding(.horizontal, 32)
        .padding(.bottom, 32)
        .animation(.easeInOut(duration: 0.22), value: showLyricsOnMobile)
    }

    private var minimalControls: some View {
        VStack(spacing: 22) {
            ZStack {
                MinimalTrackInfoRow()
                    .opacity(showLyricsOnMobile ? 0 : 1)
                    .allowsHitTesting(!showLyricsOnMobile)
                    .accessibilityHidden(showLyricsOnMobile)
                MinimalTrackInfoRow(actionsOnly: true)
                    .opacity(showLyricsOnMobile ? 1 : 0)
                    .allowsHitTesting(showLyricsOnMobile)
                    .accessibilityHidden(!showLyricsOnMobile)
            }
            .frame(height: 44)
            NowPlayingScrubber()
                .padding(.horizontal, 2)
                .padding(.top, 16)
            MinimalTransportControls(
                backdrop: colors,
                showQueue: $showQueueOnMobile
            )
                .padding(.horizontal, 2)
        }
        .accessibilityIdentifier("immersiveControls")
    }

    private func toggleMinimalLyrics() {
        guard showLyricsOnMobile || player.lyrics?.isEmpty == false else { return }
        showLyricsOnMobile.toggle()
    }

    private var minimalDismissGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                guard let dismissNowPlayingDragAction else { return }
                let translation = value.translation
                let isDownward = translation.height > 0
                    && abs(translation.height) > abs(translation.width)
                dismissNowPlayingDragAction.onChanged(isDownward ? translation.height : 0)
            }
            .onEnded { value in
                guard let dismissNowPlayingDragAction else { return }
                let translation = value.translation
                let isDownward = translation.height > 0
                    && abs(translation.height) > abs(translation.width)
                dismissNowPlayingDragAction.onEnded(
                    isDownward ? translation.height : 0,
                    isDownward ? value.predictedEndTranslation.height : 0
                )
            }
    }
    #endif

    // MARK: - Views

    private func artworkView(size: CGFloat) -> some View {
        Group {
            if let artworkImage {
                Image(platformImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.white.opacity(0.06))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 36, y: 18)
        .scaleEffect(player.isPlaying ? 1 : 0.95)
        .animation(AppAnimation.bouncy, value: player.isPlaying)
    }

    private var trackMetaView: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(player.currentTrack?.name ?? "")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if player.currentTrack?.fee == 1 {
                    VIPBadge()
                }
            }
            Text("\(player.currentTrack?.artistNames ?? "") — \(player.currentTrack?.album.name ?? "")")
                .font(.system(size: 13.5))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
        }
        .frame(maxWidth: 400)
    }

    private func leftColumn(artworkSize: CGFloat) -> some View {
        VStack(spacing: 26) {
            Spacer()

            artworkView(size: artworkSize)
            trackMetaView

            VStack(spacing: 14) {
                NowPlayingScrubber()
                    .frame(maxWidth: 380)
                controls
            }

            Spacer()
        }
        .padding(.trailing, hasLyricsColumn ? 30 : 0)
    }

    private var controls: some View {
        // Equal-width slots so the row always fits the screen: fixed-size
        // buttons in a plain HStack summed wider than a phone (≈430pt with the
        // like button), overflowing the layout and shoving the overlays and
        // metadata off the right edge. `maxWidth: .infinity` per control makes
        // the row scale to any width instead.
        HStack(spacing: 0) {
            if let track = player.currentTrack {
                let liked = account.isLiked(track.id)
                circleButton(
                    icon: liked ? "heart.fill" : "heart",
                    size: 15, tint: liked ? Theme.accent : nil
                ) {
                    Task { await account.toggleLike(trackID: track.id) }
                }
                .frame(maxWidth: .infinity)
            }

            if player.isFMMode {
                circleButton(icon: "trash", size: 14) {
                    player.fmTrash()
                }
                .frame(maxWidth: .infinity)
            } else {
                circleButton(
                    icon: "shuffle", size: 14,
                    tint: player.shuffleEnabled ? Theme.accent : nil
                ) {
                    player.toggleShuffle()
                }
                .frame(maxWidth: .infinity)
                // The third queue state. `autoMixOrderAvailable` is false on
                // iOS and with AutoMix off, so the row keeps its present
                // width everywhere the mode could not do anything anyway.
                if player.autoMixOrderAvailable {
                    circleButton(
                        icon: "wand.and.stars", size: 14,
                        tint: player.queueOrder == .autoMix ? Theme.accent : nil
                    ) {
                        player.toggleAutoMixOrder()
                    }
                    .frame(maxWidth: .infinity)
                }
                circleButton(icon: "backward.fill", size: 16) {
                    player.previous()
                }
                .frame(maxWidth: .infinity)
            }

            playPauseButton
                .frame(maxWidth: .infinity)

            circleButton(icon: "forward.fill", size: 16) {
                player.next()
            }
            .frame(maxWidth: .infinity)

            RoutePickerButton(diameter: 40, glyphSize: 15)
                .frame(maxWidth: .infinity)

            if player.isFMMode {
                Image(systemName: "wave.3.right.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 40, height: 40)
                    .frame(maxWidth: .infinity)
            } else {
                circleButton(
                    icon: player.repeatMode == .one ? "repeat.1" : "repeat",
                    size: 14,
                    tint: player.repeatMode != .off ? Theme.accent : nil
                ) {
                    player.cycleRepeatMode()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var playPauseButton: some View {
        Button {
            player.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 58, height: 58)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .contentTransition(.opacity)
            }
        }
        .buttonStyle(.pressable)
    }

    private func circleButton(icon: String, size: CGFloat,
                              tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint ?? .white.opacity(0.8))
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.1), in: Circle())
        }
        .buttonStyle(.pressable)
    }

    // MARK: - Lyrics column

    @ViewBuilder
    private var lyricsColumn: some View {
        if let lyrics = player.lyrics, !lyrics.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        Color.clear.frame(height: 200)
                        ForEach(lyrics.lines) { line in
                            bigLyricLine(line, isActive: line.id == activeIndex)
                                .id(line.id)
                        }
                        Color.clear.frame(height: 240)
                    }
                    .padding(.horizontal, 24)
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.12),
                            .init(color: .black, location: 0.85),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .onChange(of: lyricsCursor.activeIndex) { index in
                    guard index != activeIndex else { return }
                    activeIndex = index
                    guard !isUserScrolling, let index else { return }
                    withAnimation(.spring(response: 0.8, dampingFraction: 0.85)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
                .onAppear {
                    // The cursor only fires on a line change, which can be many
                    // seconds away — on re-entering the page, adopt where the
                    // song already is instead of waiting for the next line.
                    adoptCursor(proxy: proxy)
                }
                .onChange(of: player.currentTrack?.id) { _ in
                    activeIndex = nil
                }
                .simultaneousGesture(
                    DragGesture().onChanged { _ in
                        isUserScrolling = true
                        resumeTask?.cancel()
                        resumeTask = Task {
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled else { return }
                            isUserScrolling = false
                        }
                    }
                )
            }
        } else if player.lyrics?.isInstrumental == true {
            VStack(spacing: 10) {
                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
                Text("纯音乐，请欣赏")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func bigLyricLine(_ line: LyricLine, isActive: Bool) -> some View {
        Button {
            player.seek(to: line.time)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if settings.showLyricsRomaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: isActive ? 15 : 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                }
                LyricMainText(
                    line: line, isActive: isActive,
                    font: .system(size: isActive ? 26 : 20, weight: isActive ? .bold : .semibold),
                    verbatim: settings.verbatimLyrics
                )
                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: isActive ? 16 : 14, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .blur(radius: isActive ? 0 : 0.6)
            .scaleEffect(isActive ? 1.02 : 1, anchor: .leading)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isActive)
    }
}


/// The main lyric line. Renders karaoke-style per-character highlighting from
/// verbatim (`yrc`) timings, driven live by the player, when the line is active
/// and verbatim data exists; otherwise a plain line.
struct LyricMainText: View {
    let line: LyricLine
    let isActive: Bool
    let font: Font
    let verbatim: Bool
    var inactiveOpacity: Double = 0.45

    @EnvironmentObject private var player: PlayerService

    var body: some View {
        if isActive, verbatim, let words = line.words, !words.isEmpty {
            TimelineView(.animation(paused: !player.isPlaying)) { _ in
                karaoke(words, at: player.livePlaybackTime).font(font)
            }
        } else {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(font)
                .foregroundStyle(.white.opacity(isActive ? 1 : inactiveOpacity))
        }
    }

    /// One concatenated `Text` (so it wraps) with per-character opacity: sung
    /// characters are bright, the current one fades in, unsung stay dim.
    private func karaoke(_ words: [LyricWord], at time: TimeInterval) -> Text {
        let unsung = 0.28
        var out = Text(verbatim: "")
        for word in words {
            let chars = Array(word.text)
            let per = chars.isEmpty ? word.duration : word.duration / Double(chars.count)
            for (i, ch) in chars.enumerated() {
                let charStart = word.start + per * Double(i)
                let frac = per > 0 ? min(max((time - charStart) / per, 0), 1)
                                   : (time >= charStart ? 1 : 0)
                let alpha = unsung + (1 - unsung) * frac
                out = out + Text(verbatim: String(ch)).foregroundColor(.white.opacity(alpha))
            }
        }
        return out
    }
}

#if os(iOS)
private struct IOSImmersiveLyricsColumn: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor
    @EnvironmentObject private var settings: SettingsManager

    @State private var activeIndex: Int?
    @State private var isUserScrolling = false
    @State private var resumeTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let lyrics = player.lyrics, !lyrics.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            Color.clear.frame(height: 72)
                            ForEach(lyrics.lines) { line in
                                lyricLine(line, isActive: line.id == activeIndex)
                                    .id(line.id)
                            }
                            Color.clear.frame(height: 96)
                        }
                        .padding(.horizontal, 2)
                    }
                    .mask(edgeMask)
                    .accessibilityIdentifier("syncedLyricsScroll")
                    .onChange(of: lyricsCursor.activeIndex) { index in
                        guard index != activeIndex else { return }
                        activeIndex = index
                        guard !isUserScrolling, let index else { return }
                        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.38)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                    .onAppear {
                        adoptCursor(proxy: proxy)
                    }
                    .onChange(of: player.currentTrack?.id) { _ in
                        activeIndex = nil
                    }
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { _ in
                                guard !isUserScrolling else { return }
                                resumeTask?.cancel()
                                isUserScrolling = true
                            }
                            .onEnded { _ in
                                resumeTask?.cancel()
                                resumeTask = Task {
                                    try? await Task.sleep(for: .seconds(3))
                                    guard !Task.isCancelled else { return }
                                    isUserScrolling = false
                                }
                            }
                    )
                }
            } else if player.lyrics?.isInstrumental == true {
                VStack(spacing: 10) {
                    Image(systemName: "music.quarternote.3")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("纯音乐，请欣赏")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDisappear {
            resumeTask?.cancel()
        }
    }


    /// Jump straight to the line the song is on. Used when the view appears,
    /// where waiting for the next line change would leave the lyrics parked at
    /// the top. Scrolling is deferred a turn: the list has not laid out yet
    /// while `onAppear` runs, and `scrollTo` on an unlaid list does nothing.
    private func adoptCursor(proxy: ScrollViewProxy) {
        let index = lyricsCursor.activeIndex
        activeIndex = index
        guard let index else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    private var edgeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.85),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func lyricLine(_ line: LyricLine, isActive: Bool) -> some View {
        Button {
            player.seek(to: line.time)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if settings.showLyricsRomaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: isActive ? 15 : 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                }

                LyricMainText(
                    line: line, isActive: isActive,
                    font: .system(size: 27, weight: isActive ? .bold : .semibold),
                    verbatim: settings.verbatimLyrics
                )

                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .scaleEffect(isActive ? 1.07 : 0.82, anchor: .leading)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: isActive)
    }
}

// MARK: - Compact now-playing sections

private enum ImmersiveArtworkTransition {
    /// A time-based ease-out curve stays fluid at the display's native refresh rate.
    static let animation = Animation.timingCurve(
        0.16,
        1,
        0.3,
        1,
        duration: 0.42
    )
    static let compactArtworkDimension: CGFloat = 62
    static let compactHeaderSpacing: CGFloat = 13
    static let expandedMetadataOffset = -(
        compactArtworkDimension + compactHeaderSpacing
    )
}

private enum ImmersiveArtworkFrame: Hashable {
    case compact
    case expanded
}

private struct ImmersiveArtworkFramePreferenceKey: PreferenceKey {
    static var defaultValue: [ImmersiveArtworkFrame: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [ImmersiveArtworkFrame: Anchor<CGRect>],
        nextValue: () -> [ImmersiveArtworkFrame: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct CompactTrackHeader: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @State private var showAddToPlaylist = false

    let showsExpandedArtwork: Bool

    var body: some View {
        HStack(spacing: ImmersiveArtworkTransition.compactHeaderSpacing) {
            Color.clear
                .frame(
                    width: ImmersiveArtworkTransition.compactArtworkDimension,
                    height: ImmersiveArtworkTransition.compactArtworkDimension
                )
                .anchorPreference(
                    key: ImmersiveArtworkFramePreferenceKey.self,
                    value: .bounds
                ) { [.compact: $0] }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(player.currentTrack?.name ?? "")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if player.currentTrack?.fee == 1 {
                        VIPBadge()
                    }
                }
                Text(player.currentTrack?.artistNames ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(
                x: showsExpandedArtwork
                    ? ImmersiveArtworkTransition.expandedMetadataOffset
                    : 0
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("immersiveTrackMetadata")

            if let track = player.currentTrack {
                let liked = account.isLiked(track.id)
                HStack(spacing: 0) {
                    Button {
                        Task { await account.toggleLike(trackID: track.id) }
                    } label: {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(liked ? Theme.accent : .white.opacity(0.88))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel(liked ? "取消收藏" : "收藏")
                    .accessibilityIdentifier("immersiveFavoriteButton")

                    Menu {
                        Button {
                            player.addToPlayNext(track)
                        } label: {
                            Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }

                        Button {
                            showAddToPlaylist = true
                        } label: {
                            Label("加入歌单…", systemImage: "music.note.list")
                        }

                        Divider()

                        Button {
                            Platform.copyToPasteboard(
                                string: "https://music.163.com/#/song?id=\(track.id)"
                            )
                            ToastCenter.shared.show(String(localized: "链接已复制"))
                        } label: {
                            Label("复制链接", systemImage: "link")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("更多操作")
                    .accessibilityIdentifier("immersiveMoreMenu")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack {
                AddToPlaylistSheet(track: track)
            }
        }
    }
}

private struct CompactTransportControls: View {
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        HStack(spacing: 0) {
            Button(action: player.isFMMode ? player.fmTrash : player.previous) {
                Image(systemName: player.isFMMode ? "trash" : "backward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel(player.isFMMode ? "不喜欢" : "上一首")

            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 36, weight: .bold))
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Button(action: player.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel("下一首")
        }
        .foregroundStyle(.white)
        .buttonStyle(.pressable)
    }
}

private struct CompactVolumeControl: View {
    @EnvironmentObject private var player: PlayerService
    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
            // One GeometryReader with the gesture on the ZStack. A nested
            // GeometryReader (the old TranslucentSliderTrack) silently dropped
            // the drag, so the volume slider did nothing (#37).
            GeometryReader { geo in
                let width = geo.size.width
                let fraction = min(max(CGFloat(player.volume), 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.28))
                    Capsule().fill(.white.opacity(0.78))
                        .frame(width: width * fraction)
                }
                .frame(height: isDragging ? 10 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            updateVolume(at: value.location.x, width: width)
                        }
                        .onEnded { value in
                            updateVolume(at: value.location.x, width: width)
                            isDragging = false
                        }
                )
                .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isDragging)
            }
            .frame(height: 24)
            .accessibilityElement()
            .accessibilityLabel("音量")
            .accessibilityValue("\(Int((player.volume * 100).rounded()))%")
            .accessibilityAdjustableAction(adjustVolume)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
        }
        .foregroundStyle(.white.opacity(0.7))
    }

    private func updateVolume(at location: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        player.volume = Float(min(max(location / width, 0), 1))
    }

    private func adjustVolume(_ direction: AccessibilityAdjustmentDirection) {
        let step: Float = 0.05
        switch direction {
        case .increment:
            player.volume = min(player.volume + step, 1)
        case .decrement:
            player.volume = max(player.volume - step, 0)
        @unknown default:
            break
        }
    }
}

private struct CompactSecondaryControls: View {
    @EnvironmentObject private var player: PlayerService
    let showsLyrics: Bool
    let showsQueue: Bool
    let onToggleLyrics: () -> Void
    let onToggleQueue: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            secondaryButton(
                icon: showsLyrics && !showsQueue ? "quote.bubble.fill" : "quote.bubble",
                label: showsLyrics ? "显示封面" : "显示歌词",
                isActive: showsLyrics && !showsQueue
            ) { onToggleLyrics() }

            RoutePickerButton(diameter: 44, glyphSize: 17)
                .frame(maxWidth: .infinity)

            secondaryButton(
                icon: "list.bullet",
                label: showsQueue ? "关闭播放队列" : "显示播放队列",
                isActive: showsQueue
            ) { onToggleQueue() }
        }
    }

    private func secondaryButton(
        icon: String,
        label: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isActive ? Theme.accent : .white.opacity(0.72))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.08), in: Circle())
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct CompactQueueContent: View {
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                modeButton(
                    icon: "arrow.right",
                    label: "顺序播放",
                    isActive: !player.shuffleEnabled && player.repeatMode == .off,
                    action: enableSequentialPlayback
                )
                modeButton(
                    icon: "shuffle",
                    label: player.shuffleEnabled ? "关闭随机播放" : "随机播放",
                    isActive: player.shuffleEnabled,
                    action: player.toggleShuffle
                )
                modeButton(
                    icon: "repeat",
                    label: "列表循环",
                    isActive: player.repeatMode == .all
                ) {
                    player.repeatMode = player.repeatMode == .all ? .off : .all
                }
                modeButton(
                    icon: "repeat.1",
                    label: "单曲循环",
                    isActive: player.repeatMode == .one
                ) {
                    player.repeatMode = player.repeatMode == .one ? .off : .one
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text("继续播放")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(player.upcomingTracks.count) 首")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.46))
            }

            if player.upcomingTracks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 28, weight: .light))
                    Text("播放队列是空的")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(
                            Array(player.upcomingTracks.prefix(100).enumerated()),
                            id: \.offset
                        ) { _, track in
                            CompactQueueRow(track: track)
                        }
                    }
                }
                .mask(
                    LinearGradient(
                        colors: [.black, .black, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .padding(.top, 6)
    }

    private func modeButton(
        icon: String,
        label: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isActive ? Color.black.opacity(0.76) : .white.opacity(0.76))
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(
                    isActive ? AnyShapeStyle(.white.opacity(0.66)) : AnyShapeStyle(.white.opacity(0.1)),
                    in: Capsule()
                )
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func enableSequentialPlayback() {
        if player.shuffleEnabled {
            player.toggleShuffle()
        }
        player.repeatMode = .off
    }
}

private struct CompactQueueRow: View {
    let track: Track

    @EnvironmentObject private var player: PlayerService

    var body: some View {
        Button {
            player.jumpTo(track)
        } label: {
            HStack(spacing: 11) {
                CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(120), animated: false)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(track.artistNames)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text(Formatters.duration(track.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.36))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(track.name)，\(track.artistNames)")
    }
}



private struct IOSMinimalLyricsColumn: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var clock = PlayerService.shared.clock
    @EnvironmentObject private var settings: SettingsManager

    let onClose: () -> Void

    @State private var activeIndex: Int?
    @State private var selectedIndex: Int?
    @State private var nearestIndex: Int?
    @State private var lineCenters: [Int: CGFloat] = [:]
    @State private var isDragging = false
    @State private var suppressesAutoScroll = false
    @State private var scrollSettleTask: Task<Void, Never>?
    @State private var selectionTimeoutTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let lyrics = player.lyrics, !lyrics.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                Color.clear.frame(height: geometry.size.height / 2)
                                ForEach(lyrics.lines) { line in
                                    lyricLine(
                                        line,
                                        isActive: line.id == activeIndex,
                                        isSelected: line.id == selectedIndex,
                                        availableWidth: geometry.size.width
                                    ) {
                                        guard let selectedIndex else {
                                            closeLyrics()
                                            return
                                        }
                                        guard selectedIndex == line.id else {
                                            returnToActiveLine(proxy: proxy)
                                            return
                                        }
                                        selectionTimeoutTask?.cancel()
                                        selectionTimeoutTask = nil
                                        suppressesAutoScroll = true
                                        player.seek(to: line.time) {
                                            suppressesAutoScroll = false
                                        }
                                        activeIndex = line.id
                                        self.selectedIndex = nil
                                        nearestIndex = nil
                                    }
                                    .id(line.id)
                                    .background {
                                        GeometryReader { lineGeometry in
                                            Color.clear.preference(
                                                key: MinimalLyricCentersKey.self,
                                                value: [
                                                    line.id: lineGeometry.frame(
                                                        in: .named("immersiveLyrics")
                                                    ).midY
                                                ]
                                            )
                                        }
                                    }
                                }
                                Color.clear.frame(height: geometry.size.height / 2)
                            }
                            .padding(.horizontal, 2)
                        }
                        .coordinateSpace(name: "immersiveLyrics")
                        .mask(edgeMask)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: closeLyrics)
                        .accessibilityIdentifier("syncedLyricsScroll")
                        .onPreferenceChange(MinimalLyricCentersKey.self) { centers in
                            lineCenters = centers
                            guard isDragging || scrollSettleTask != nil else { return }
                            nearestIndex = nearestLine(
                                to: geometry.size.height / 2,
                                in: centers
                            )
                            guard !isDragging else { return }
                            scheduleScrollSelection(
                                guideY: geometry.size.height / 2,
                                proxy: proxy
                            )
                        }
                        .onAppear {
                            activeIndex = lyrics.activeIndex(at: clock.progress + 0.2)
                            if let activeIndex {
                                Task { @MainActor in
                                    await Task.yield()
                                    proxy.scrollTo(activeIndex, anchor: .center)
                                }
                            }
                        }
                        .onChange(of: clock.progress) { _ in
                            let index = lyrics.activeIndex(at: clock.progress + 0.2)
                            guard index != activeIndex else { return }
                            activeIndex = index
                            guard !suppressesAutoScroll,
                                  !isDragging, scrollSettleTask == nil,
                                  selectedIndex == nil, let index else { return }
                            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.38)) {
                                proxy.scrollTo(index, anchor: .center)
                            }
                        }
                        .onChange(of: player.currentTrack?.id) { _ in
                            activeIndex = nil
                            selectedIndex = nil
                            nearestIndex = nil
                            suppressesAutoScroll = false
                            scrollSettleTask?.cancel()
                            scrollSettleTask = nil
                            selectionTimeoutTask?.cancel()
                            selectionTimeoutTask = nil
                        }
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { _ in
                                    if !isDragging {
                                        scrollSettleTask?.cancel()
                                        scrollSettleTask = nil
                                        selectionTimeoutTask?.cancel()
                                        selectionTimeoutTask = nil
                                        selectedIndex = nil
                                        isDragging = true
                                    }
                                    nearestIndex = nearestLine(
                                        to: geometry.size.height / 2,
                                        in: lineCenters
                                    )
                                }
                                .onEnded { _ in
                                    isDragging = false
                                    scheduleScrollSelection(
                                        guideY: geometry.size.height / 2,
                                        proxy: proxy
                                    )
                                }
                        )
                        .overlay {
                            selectionGuide(lyrics: lyrics)
                        }
                    }
                } else if player.lyrics?.isInstrumental == true {
                    VStack(spacing: 10) {
                        Image(systemName: "music.quarternote.3")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.white.opacity(0.4))
                        Text("纯音乐，请欣赏")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: closeLyrics)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onDisappear {
            scrollSettleTask?.cancel()
            selectionTimeoutTask?.cancel()
        }
    }

    @ViewBuilder
    private func selectionGuide(lyrics: ParsedLyrics) -> some View {
        let isScrolling = isDragging || scrollSettleTask != nil
        if let index = isScrolling ? nearestIndex : selectedIndex,
           lyrics.lines.indices.contains(index) {
            HStack(spacing: 8) {
                if isScrolling {
                    Canvas { context, size in
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: size.height / 2))
                        path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                        context.stroke(
                            path,
                            with: .color(.white.opacity(0.45)),
                            style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                        )
                    }
                    .frame(height: 1)
                } else {
                    Spacer()
                }

                Text(Formatters.duration(lyrics.lines[index].time))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
                    .offset(x: 25)
            }
            .padding(.horizontal, 2)
            .allowsHitTesting(false)
        }
    }

    private func nearestLine(to guideY: CGFloat, in centers: [Int: CGFloat]) -> Int? {
        centers.min { abs($0.value - guideY) < abs($1.value - guideY) }?.key
    }

    private func scheduleScrollSelection(guideY: CGFloat, proxy: ScrollViewProxy) {
        scrollSettleTask?.cancel()
        // ponytail: iOS 16 has no scroll phase API; replace with onScrollPhaseChange
        // when the deployment target reaches iOS 18.
        scrollSettleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let selection = nearestLine(to: guideY, in: lineCenters) ?? nearestIndex
            selectedIndex = selection
            nearestIndex = selection
            scrollSettleTask = nil
            guard let selection else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                proxy.scrollTo(selection, anchor: .center)
            }
            scheduleSelectionTimeout(proxy: proxy)
        }
    }

    private func scheduleSelectionTimeout(proxy: ScrollViewProxy) {
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, selectedIndex != nil else { return }
            returnToActiveLine(proxy: proxy)
        }
    }

    private func returnToActiveLine(proxy: ScrollViewProxy) {
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = nil
        selectedIndex = nil
        nearestIndex = nil
        guard let activeIndex else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            proxy.scrollTo(activeIndex, anchor: .center)
        }
    }

    private func closeLyrics() {
        scrollSettleTask?.cancel()
        scrollSettleTask = nil
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = nil
        selectedIndex = nil
        nearestIndex = nil
        isDragging = false
        onClose()
    }

    private var edgeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.85),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func lyricLine(
        _ line: LyricLine,
        isActive: Bool,
        isSelected: Bool,
        availableWidth: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                if settings.showLyricsRomaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                        .fixedSize(horizontal: false, vertical: true)
                        .scaleEffect(isActive ? 1.02 : 12.0 / 13.0, anchor: .leading)
                }

                LyricMainText(
                    line: line, isActive: isActive,
                    font: .system(size: 17, weight: .bold),
                    verbatim: settings.verbatimLyrics
                )
                    .fixedSize(horizontal: false, vertical: true)
                    .scaleEffect(isActive ? 1.02 : 16.0 / 17.0, anchor: .leading)

                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                        .fixedSize(horizontal: false, vertical: true)
                        .scaleEffect(isActive ? 1.02 : 12.0 / 13.0, anchor: .leading)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.14 : 0))
            )
            .contentShape(Rectangle())
            .padding(.trailing, availableWidth * (1 - 1 / 1.02))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: isActive)
        .animation(.easeOut(duration: 0.18), value: isSelected)
    }
}

private struct MinimalLyricCentersKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

// MARK: - Minimal track info row

private struct MinimalTrackInfoRow: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @State private var showAddToPlaylist = false
    @State private var airPlayRequest = 0
    var metadataOnly = false
    var actionsOnly = false

    var body: some View {
        Group {
            if metadataOnly {
                metadata(alignment: .center, textAlignment: .center)
                    .padding(.horizontal, 48)
            } else if actionsOnly {
                if let track = player.currentTrack {
                    HStack {
                        favoriteButton(for: track)
                        Spacer()
                        moreMenu(for: track)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    metadata(alignment: .leading, textAlignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let track = player.currentTrack {
                        favoriteButton(for: track)
                        moreMenu(for: track)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack {
                AddToPlaylistSheet(track: track)
            }
        }
    }

    private func metadata(
        alignment: HorizontalAlignment,
        textAlignment: TextAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            HStack(spacing: 6) {
                Text(player.currentTrack?.name ?? "")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if player.currentTrack?.fee == 1 {
                    VIPBadge()
                }
            }
            Text(player.currentTrack?.artistNames ?? "")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
        }
        .multilineTextAlignment(textAlignment)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("immersiveTrackMetadata")
    }

    private func favoriteButton(for track: Track) -> some View {
        let liked = account.isLiked(track.id)
        return Button {
            Task { await account.toggleLike(trackID: track.id) }
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(liked ? Theme.accent : .white.opacity(0.88))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(liked ? "取消收藏" : "收藏")
        .accessibilityIdentifier("immersiveFavoriteButton")
    }

    private func moreMenu(for track: Track) -> some View {
        Menu {
            Button {
                airPlayRequest += 1
            } label: {
                Label("AirPlay", systemImage: "airplayaudio")
            }

            Button {
                player.addToPlayNext(track)
            } label: {
                Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                showAddToPlaylist = true
            } label: {
                Label("加入歌单…", systemImage: "music.note.list")
            }

            Divider()

            Button {
                Platform.copyToPasteboard(
                    string: "https://music.163.com/#/song?id=\(track.id)"
                )
                ToastCenter.shared.show(String(localized: "链接已复制"))
            } label: {
                Label("复制链接", systemImage: "link")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("更多操作")
        .accessibilityIdentifier("immersiveMoreMenu")
        .background {
            RoutePickerButton(
                diameter: 1, glyphSize: 1, request: airPlayRequest,
                tint: .clear, background: .clear
            )
            .opacity(0.01)
        }
    }
}

private struct MinimalTransportControls: View {
    @EnvironmentObject private var player: PlayerService
    let backdrop: ArtworkColors
    @Binding var showQueue: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityLabel("播放列表")
            .accessibilityIdentifier("immersivePlaylistButton")
                .frame(maxWidth: .infinity)

            Button(action: player.isFMMode ? player.fmTrash : player.previous) {
                Image(systemName: player.isFMMode ? "trash" : "backward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel(player.isFMMode ? "不喜欢" : "上一首")

            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 38, weight: .bold))
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Button(action: player.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel("下一首")

            playbackModeButton
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .buttonStyle(.pressable)
        .sheet(isPresented: $showQueue) {
            queueSheet
        }
    }

    @ViewBuilder
    private var queueSheet: some View {
        if #available(iOS 16.4, *) {
            MinimalQueueSheet(backdrop: backdrop)
                .presentationDetents([.fraction(0.5)])
                .presentationBackgroundInteraction(.enabled)
        } else {
            MinimalQueueSheet(backdrop: backdrop)
                .presentationDetents([.fraction(0.5)])
        }
    }

    @ViewBuilder
    private var playbackModeButton: some View {
        if player.isFMMode {
            Color.clear
                .frame(height: 44)
        } else {
            Button(action: player.cyclePlaybackMode) {
                Image(systemName: playbackModeIcon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(playbackModeTint)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playbackModeLabel)
        }
    }

    private var playbackModeIcon: String {
        if player.shuffleEnabled { return "shuffle" }
        switch player.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private var playbackModeTint: Color {
        (player.shuffleEnabled || player.repeatMode != .off)
            ? Theme.accent
            : .white.opacity(0.88)
    }

    private var playbackModeLabel: String {
        if player.shuffleEnabled { return "随机播放" }
        switch player.repeatMode {
        case .off: return "顺序播放"
        case .all: return "列表循环"
        case .one: return "单曲循环"
        }
    }
}

private struct MinimalQueueSheet: View {
    @EnvironmentObject private var player: PlayerService
    let backdrop: ArtworkColors

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    if let current = player.currentTrack {
                        MinimalQueueSectionLabel("正在播放")
                        MinimalQueueRow(track: current, isCurrent: true)

                        if !player.upcomingTracks.isEmpty {
                            MinimalQueueSectionLabel("即将播放")
                                .padding(.top, 10)
                            ForEach(
                                Array(player.upcomingTracks.prefix(100).enumerated()),
                                id: \.offset
                            ) { _, track in
                                MinimalQueueRow(track: track, isCurrent: false)
                            }
                        }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 28, weight: .light))
                            Text("播放队列是空的")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .padding(10)
            }
            .navigationTitle("播放列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(player.upcomingTracks.count + (player.hasCurrentTrack ? 1 : 0)) 首")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .background(queueBackdrop)
    }

    private var queueBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [backdrop.primary, backdrop.secondary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Color.black.opacity(0.45)
        }
        .ignoresSafeArea()
    }
}

private struct MinimalQueueSectionLabel: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

private struct MinimalQueueRow: View {
    let track: Track
    let isCurrent: Bool

    @EnvironmentObject private var player: PlayerService

    var body: some View {
        Button {
            guard !isCurrent else { return }
            player.jumpTo(track)
        } label: {
            HStack(spacing: 10) {
                CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(96), animated: false)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(isCurrent ? Theme.accent : .primary)
                        .lineLimit(1)
                    Text(track.artistNames)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isCurrent {
                    PlayingIndicator(animating: player.isPlaying)
                } else {
                    Text(Formatters.duration(track.duration))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#endif


// MARK: - Scrubber (white-on-dark variant)

struct NowPlayingScrubber: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var clock = PlayerService.shared.clock

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    private var fraction: Double {
        guard player.duration > 0 else { return 0 }
        let value = isDragging ? dragProgress : clock.progress
        return min(max(value / player.duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.25))
                        .frame(height: 4)
                    Capsule()
                        .fill(.white)
                        .frame(width: max(4, width * fraction), height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: thumbDiameter, height: thumbDiameter)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: width * fraction - thumbDiameter / 2)
                        .opacity(isHovering || isDragging ? 1 : 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard player.duration > 0 else { return }
                            isDragging = true
                            player.isScrubbing = true
                            dragProgress = min(max(value.location.x / width, 0), 1) * player.duration
                        }
                        .onEnded { _ in
                            player.seek(to: dragProgress)
                            isDragging = false
                            player.isScrubbing = false
                        }
                )
            }
            .frame(height: 14)
            .onHover { hovering in
                withAnimation(AppAnimation.quick) { isHovering = hovering }
            }

            HStack {
                Text(Formatters.duration(isDragging ? dragProgress : clock.progress))
                Spacer()
                Text(Formatters.duration(player.duration))
            }
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var thumbDiameter: CGFloat {
        isDragging ? 13 : (isHovering ? 11 : 9)
    }
}

// MARK: - Mini lyrics (compact now-playing)

/// Three synced lyric lines (previous / current / next) filling the gap
/// between the track meta and the transport controls on compact layouts.
/// Tapping opens the full lyrics page.
struct MiniLyricsView: View {
    let onOpen: () -> Void

    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor

    private var lines: (previous: LyricLine?, current: LyricLine?, next: LyricLine?) {
        guard let lyrics = player.lyrics, !lyrics.isEmpty else { return (nil, nil, nil) }
        guard let index = lyricsCursor.activeIndex else {
            return (nil, nil, lyrics.lines.first)
        }
        let all = lyrics.lines
        return (
            index > 0 ? all[index - 1] : nil,
            all[index],
            index + 1 < all.count ? all[index + 1] : nil
        )
    }

    var body: some View {
        let (previous, current, next) = lines
        Group {
            if current != nil || next != nil {
                VStack(spacing: 12) {
                    line(previous, emphasized: false)
                    line(current, emphasized: true)
                    line(next, emphasized: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: current?.id)
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private func line(_ line: LyricLine?, emphasized: Bool) -> some View {
        Text(line?.text.isEmpty == false ? line!.text : " ")
            .font(.system(size: emphasized ? 17 : 14, weight: emphasized ? .bold : .medium))
            .foregroundStyle(.white.opacity(emphasized ? 1 : 0.45))
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .id(line?.id)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
