import SwiftUI

/// Complete interactive turntable stage combining rotating vinyl disc, tonearm,
/// continuous timeline rotation, tap-to-flip, and horizontal swipe-to-switch tracks.
public struct VinylTurntableView: View {
    public let artworkImage: PlatformImage?
    public let isPlaying: Bool
    public let trackId: Int?
    public let size: CGFloat
    public var onTap: (() -> Void)? = nil
    public var onNextTrack: (() -> Void)? = nil
    public var onPreviousTrack: (() -> Void)? = nil

    @State private var rotationState = RecordRotationState()
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var isTransitioningTrack = false
    @ObservedObject private var windowVisibility = MainWindowVisibility.shared

    public init(
        artworkImage: PlatformImage?,
        isPlaying: Bool,
        trackId: Int? = nil,
        size: CGFloat = 280,
        onTap: (() -> Void)? = nil,
        onNextTrack: (() -> Void)? = nil,
        onPreviousTrack: (() -> Void)? = nil
    ) {
        self.artworkImage = artworkImage
        self.isPlaying = isPlaying
        self.trackId = trackId
        self.size = size
        self.onTap = onTap
        self.onNextTrack = onNextTrack
        self.onPreviousTrack = onPreviousTrack
    }

    public var body: some View {
        let discSize = size
        let armHeight = discSize * 0.68
        let stageWidth = discSize + 48
        let stageHeight = discSize + armHeight * 0.38

        return ZStack(alignment: .top) {
            // MARK: 1. Rotating Vinyl Disc (with horizontal drag & slide transitions)
            TimelineView(.animation(
                paused: !isPlaying || isDragging || isTransitioningTrack
                    || !windowVisibility.isVisible
            )) { timeline in
                let currentAngle = rotationState.currentAngle(at: timeline.date)

                VinylRecordView(artworkImage: artworkImage, size: discSize)
                    .rotationEffect(.degrees(currentAngle))
            }
            .offset(x: dragOffset)
            .padding(.top, armHeight * 0.36)
            .contentShape(Circle())
            .gesture(dragAndSwipeGesture(discSize: discSize))
            .onTapGesture {
                onTap?()
            }
            .zIndex(1)

            // MARK: 2. Tonearm (Placed at the top-center above the disc, reaching down)
            VinylTonearmView(
                isPlaying: isPlaying && !isDragging && !isTransitioningTrack,
                height: armHeight
            )
            .offset(x: discSize * 0.12, y: -armHeight * 0.08)
            .allowsHitTesting(false)
            .zIndex(2)
        }
        .frame(width: stageWidth, height: stageHeight, alignment: .top)
        .onAppear {
            if isPlaying {
                rotationState.start(at: Date())
            }
        }
        .onChange(of: isPlaying) { playing in
            if playing {
                rotationState.start(at: Date())
            } else {
                rotationState.stop(at: Date())
            }
        }
        .onChange(of: trackId) { _ in
            // Temporarily lift tonearm on track change
            isTransitioningTrack = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 320_000_000)
                isTransitioningTrack = false
            }
        }
    }

    // MARK: - Gestures

    private func dragAndSwipeGesture(discSize: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                // Only track horizontal gestures
                if abs(value.translation.width) > abs(value.translation.height) * 0.6 {
                    isDragging = true
                    let raw = value.translation.width
                    // Damped elastic feel
                    dragOffset = raw
                }
            }
            .onEnded { value in
                let translation = value.translation.width
                let velocity = value.predictedEndTranslation.width
                let swipeThreshold: CGFloat = 45

                if translation < -swipeThreshold || velocity < -100 {
                    // Swipe Left -> Next Track (下一首)
                    withAnimation(.easeOut(duration: 0.20)) {
                        dragOffset = -discSize * 1.25
                    }
                    onNextTrack?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        dragOffset = discSize * 1.25
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) {
                            dragOffset = 0
                            isDragging = false
                        }
                    }
                } else if translation > swipeThreshold || velocity > 100 {
                    // Swipe Right -> Previous Track (上一首)
                    withAnimation(.easeOut(duration: 0.20)) {
                        dragOffset = discSize * 1.25
                    }
                    onPreviousTrack?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        dragOffset = -discSize * 1.25
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) {
                            dragOffset = 0
                            isDragging = false
                        }
                    }
                } else {
                    // Reset back to center
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.76)) {
                        dragOffset = 0
                        isDragging = false
                    }
                }
            }
    }
}
