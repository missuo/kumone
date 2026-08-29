import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 860
            HStack(spacing: 12) {
                songInfoSection(compact: compact)
                    .frame(width: compact ? 180 : 252, alignment: .leading)
                centerSection
                    .frame(maxWidth: .infinity)
                optionsSection(compact: compact)
            }
            .padding(.horizontal, 14)
        }
        .frame(height: Theme.Layout.playerBarHeight)
        .compatGlass(interactive: true, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
        .padding(.horizontal, 16)
        .padding(.bottom, Theme.Layout.playerBarBottomMargin)
        .background(alignment: .bottom) { bottomFade }
    }

    // MARK: - Left: artwork + titles + like

    private func songInfoSection(compact: Bool) -> some View {
        HStack(spacing: 10) {
            artworkButton
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    MarqueeText(text: player.currentTrack?.name ?? String(localized: "未在播放"))
                        .frame(height: 17)
                    if player.currentTrack?.fee == 1 {
                        VIPBadge()
                    }
                }
                Text(player.currentTrack?.artistNames ?? "Kumone")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let track = player.currentTrack {
                LikeButton(trackID: track.id)
            }
        }
    }

    private var artworkButton: some View {
        Button {
            guard player.hasCurrentTrack else { return }
            withAnimation(AppAnimation.smooth) {
                player.showNowPlaying = true
            }
        } label: {
            CachedAsyncImage(url: player.currentTrack?.album.picUrl?.resizedImageURL(128))
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        }
        .buttonStyle(.pressable)
        .help("打开播放页")
    }

    // MARK: - Center: transport + scrubber

    private var centerSection: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                if player.isFMMode {
                    PlayerIconButton(icon: "trash", size: 12) {
                        player.fmTrash()
                    }
                    .help("不喜欢，换一首")
                } else {
                    PlayerIconButton(
                        icon: "shuffle", size: 12,
                        isActive: player.shuffleEnabled
                    ) {
                        player.toggleShuffle()
                    }
                    .help("随机播放")
                    // The third queue state, next to the one it is mutually
                    // exclusive with. Hidden rather than disabled where it
                    // could do nothing — it picks by planning, and planning
                    // needs the analyses an AutoMix-off player never computes.
                    if player.autoMixOrderAvailable {
                        PlayerIconButton(
                            icon: "wand.and.stars", size: 12,
                            isActive: player.queueOrder == .autoMix
                        ) {
                            player.toggleAutoMixOrder()
                        }
                        .help("AutoMix 顺序")
                    }
                }

                PlayerIconButton(icon: "backward.fill", size: 14, disabled: player.isFMMode) {
                    player.previous()
                }

                playPauseButton

                PlayerIconButton(icon: "forward.fill", size: 14) {
                    player.next()
                }

                if player.isFMMode {
                    Image(systemName: "wave.3.right.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 26, height: 26)
                        .help("私人漫游中")
                } else {
                    PlayerIconButton(
                        icon: player.repeatMode == .one ? "repeat.1" : "repeat", size: 12,
                        isActive: player.repeatMode != .off
                    ) {
                        player.cycleRepeatMode()
                    }
                    .help("循环模式")
                }
            }
            ScrubberLane()
        }
        .padding(.vertical, 5)
        .opacity(player.hasCurrentTrack ? 1 : 0.5)
    }

    private var playPauseButton: some View {
        Button {
            player.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .fill(Theme.accentGradient)
                    .frame(width: 30, height: 30)
                    .shadow(color: Theme.accent.opacity(0.35), radius: 5, y: 1)
                if player.isBuffering && player.isPlaying {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.opacity)
                }
            }
        }
        .buttonStyle(.pressable)
        .padding(.horizontal, 2)
    }

    // MARK: - Right: quality / panels / volume

    private func optionsSection(compact: Bool) -> some View {
        HStack(spacing: 4) {
            if !compact, let level = player.servedQuality,
               let quality = AudioQuality(rawValue: level) {
                QualityTag(text: quality.badge)
                    .padding(.trailing, 2)
            } else if !compact, player.unblockSource != nil {
                QualityTag(text: String(localized: "音源"))
                    .padding(.trailing, 2)
                    .help("来自 \(player.unblockSource ?? "")")
            }
            PlayerIconButton(
                icon: "quote.bubble", size: 13,
                isActive: player.activePanel == .lyrics
            ) {
                player.activePanel = player.activePanel == .lyrics ? nil : .lyrics
            }
            .help("歌词")
            PlayerIconButton(
                icon: "inset.filled.bottomthird.square", size: 13,
                isActive: SettingsManager.shared.showDesktopLyrics
            ) {
                SettingsManager.shared.showDesktopLyrics.toggle()
            }
            .help("桌面歌词")
            PlayerIconButton(
                icon: "list.bullet", size: 13,
                isActive: player.activePanel == .queue,
                disabled: player.isFMMode
            ) {
                player.activePanel = player.activePanel == .queue ? nil : .queue
            }
            .help("播放队列")
            #if os(macOS)
            RoutePickerButton(diameter: 26, glyphSize: 13,
                              tint: .secondary, background: .clear)
            #endif
            VolumeControl()
        }
    }

    private var bottomFade: some View {
        LinearGradient(
            colors: [
                Platform.windowBackgroundColor.opacity(0),
                Platform.windowBackgroundColor.opacity(0.25),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: 50)
        .allowsHitTesting(false)
    }
}

// MARK: - Icon button

struct PlayerIconButton: View {
    let icon: String
    var size: CGFloat = 14
    var isActive = false
    var disabled = false
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(backgroundColor)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .onHover { isHovering = $0 }
        .animation(AppAnimation.quick, value: isHovering)
    }

    private var backgroundColor: Color {
        let base: Color = colorScheme == .dark ? .white : .black
        if isHovering, !disabled { return base.opacity(0.08) }
        if isActive { return base.opacity(0.05) }
        return .clear
    }
}

// MARK: - Like button

struct LikeButton: View {
    let trackID: Int
    var size: CGFloat = 13

    @EnvironmentObject private var account: AccountStore

    var body: some View {
        let liked = account.isLiked(trackID)
        PlayerIconButton(
            icon: liked ? "heart.fill" : "heart", size: size,
            isActive: liked
        ) {
            Task { await account.toggleLike(trackID: trackID) }
        }
        .help(liked ? String(localized: "取消喜欢") : String(localized: "喜欢"))
    }
}

// MARK: - Scrubber

struct ScrubberLane: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var clock = PlayerService.shared.clock
    @Environment(\.colorScheme) private var colorScheme

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    private var fraction: Double {
        guard player.duration > 0 else { return 0 }
        let value = isDragging ? dragProgress : clock.progress
        return min(max(value / player.duration, 0), 1)
    }

    var body: some View {
        HStack(spacing: 8) {
            timeLabel(isDragging ? dragProgress : clock.progress)
            track
            timeLabel(player.duration)
        }
        .frame(maxWidth: 460)
    }

    private func timeLabel(_ value: TimeInterval) -> some View {
        Text(Formatters.duration(value))
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 34)
    }

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.18) : .black.opacity(0.15))
                    .frame(height: 3.5)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(3.5, width * fraction), height: 3.5)
                Circle()
                    .fill(.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
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
        .animation(.spring(response: 0.24, dampingFraction: 0.72), value: isDragging)
    }

    private var thumbDiameter: CGFloat {
        isDragging ? 12 : (isHovering ? 10 : 8)
    }
}

// MARK: - Volume

struct VolumeControl: View {
    @EnvironmentObject private var player: PlayerService
    @State private var showPopover = false

    var body: some View {
        PlayerIconButton(icon: volumeIcon, size: 13) {
            showPopover.toggle()
        }
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            VolumeSlider()
                .padding(.vertical, 12)
                .padding(.horizontal, 10)
        }
        .help("音量")
    }

    private var volumeIcon: String {
        switch player.volume {
        case 0: return "speaker.slash"
        case ..<0.4: return "speaker.wave.1"
        case ..<0.75: return "speaker.wave.2"
        default: return "speaker.wave.3"
        }
    }
}

struct VolumeSlider: View {
    @EnvironmentObject private var player: PlayerService
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.18) : .black.opacity(0.15))
                    .frame(width: 4)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 4, height: max(4, height * CGFloat(player.volume)))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        player.volume = Float(min(max(1 - value.location.y / height, 0), 1))
                    }
            )
        }
        .frame(width: 22, height: 110)
    }
}
