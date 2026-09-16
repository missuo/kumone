import SwiftUI

// MARK: - Lyrics panel

struct LyricsPanel: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor
    @EnvironmentObject private var settings: SettingsManager

    @State private var activeIndex: Int?
    @State private var isUserScrolling = false
    @State private var resumeTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            content
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .compatGlass(interactive: true, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("歌词")
                    .font(.headline)
                if let contributor = player.lyrics?.contributor {
                    Text("贡献者：\(contributor)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                player.activePanel = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.pressable)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if let lyrics = player.lyrics, !lyrics.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        Color.clear.frame(height: 120)
                        ForEach(lyrics.lines) { line in
                            lyricLine(line, isActive: line.id == activeIndex)
                                .id(line.id)
                        }
                        Color.clear.frame(height: 160)
                    }
                    .padding(.horizontal, 20)
                }
                .onChange(of: lyricsCursor.activeIndex) { index in
                    guard index != activeIndex else { return }
                    activeIndex = index
                    guard !isUserScrolling, let index else { return }
                    withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
                .onAppear {
                    adoptCursor(proxy: proxy)
                }
                .onChange(of: player.currentTrack?.id) { _ in
                    activeIndex = nil
                    proxy.scrollTo(0, anchor: .top)
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
            EmptyStateView(icon: "music.quarternote.3", title: "纯音乐", subtitle: "请欣赏")
        } else if player.hasCurrentTrack {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("歌词加载中…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(icon: "quote.bubble", title: "暂无歌词")
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

    private func lyricLine(_ line: LyricLine, isActive: Bool) -> some View {
        Button {
            player.seek(to: line.time)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if settings.lyricsAnnotation == .romaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: isActive ? 12 : 11))
                        .foregroundStyle(isActive ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
                LyricText(
                    line: line,
                    size: isActive ? 16 : 14,
                    weight: isActive ? .bold : .medium,
                    // Core Text needs a resolved colour, so the hierarchical
                    // styles the other rows use are spelled out here.
                    color: isActive ? .primary : .secondary
                )
                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: isActive ? 13 : 12))
                        .foregroundStyle(isActive ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(isActive ? 1 : 0.75)
            .blur(radius: isActive ? 0 : 0.3)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isActive)
    }
}

// MARK: - Queue panel

struct QueuePanel: View {
    @EnvironmentObject private var player: PlayerService
    @Environment(\.openDestination) private var openDestination

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            if let current = player.currentTrack {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        OfflineQueuePreparationView {
                            player.activePanel = nil
                            openDestination(.downloadedCollection($0))
                        }
                            .padding(.bottom, 8)
                        sectionLabel("正在播放")
                        QueueRow(track: current, isCurrent: true)

                        if !player.upcomingTracks.isEmpty {
                            sectionLabel("即将播放")
                                .padding(.top, 10)
                            ForEach(Array(player.upcomingTracks.prefix(100).enumerated()),
                                    id: \.offset) { index, track in
                                QueueRow(track: track, isCurrent: false, upcomingIndex: index)
                            }
                        }
                    }
                    .padding(10)
                }
            } else {
                EmptyStateView(icon: "list.bullet", title: "播放队列是空的",
                               subtitle: "播放一些音乐吧")
            }
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack {
            Text("播放队列")
                .font(.headline)
            Text("\(player.upcomingTracks.count + (player.hasCurrentTrack ? 1 : 0)) 首")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                player.activePanel = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.pressable)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

private struct QueueRow: View {
    let track: Track
    let isCurrent: Bool
    var upcomingIndex: Int? = nil

    @EnvironmentObject private var player: PlayerService
    @State private var isHovering = false

    var body: some View {
        Button {
            guard !isCurrent else { return }
            if let upcomingIndex { player.jumpToUpcoming(at: upcomingIndex, matching: track.id) }
            else { player.jumpTo(track) }
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
                } else if isHovering {
                    Button {
                        if let upcomingIndex { player.removeUpcoming(at: upcomingIndex, matching: track.id) }
                        else { player.removeFromUpcoming(track) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.pressable)
                } else {
                    Text(Formatters.duration(track.duration))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.interactiveRow)
        .onHover { isHovering = $0 }
    }
}
