import QuartzCore
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
            SpinningVinylDisc(
                artworkImage: artworkImage,
                discSize: discSize,
                spinning: isPlaying && !isDragging && !isTransitioningTrack
                    && windowVisibility.isVisible
            )
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

// MARK: - Disc rotation on the layer

/// Spins the disc on its own layer instead of a SwiftUI `TimelineView`.
///
/// The `TimelineView` re-evaluated the record — and with it the page's layout
/// around the whole stage — on every display frame while the song played,
/// worth a large share of a core. Rotating a `CALayer` is a compositing
/// change nothing above the hosted disc ever hears about, and
/// `RecordRotationState` still owns the angle math, so pausing and resuming
/// stay jump-free.
private final class DiscSpinController {
    private let layer: CALayer
    private var state = RecordRotationState()

    init(layer: CALayer) {
        self.layer = layer
    }

    func setSpinning(_ spinning: Bool) {
        if spinning {
            guard !state.isAnimating else { return }
            state.start(at: Date())
            // Core Animation measures angles the other way round from
            // SwiftUI: the record turns clockwise, which is a *negative*
            // z-rotation on a layer.
            let from = -state.currentAngle(at: Date()) * .pi / 180
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.setValue(from, forKeyPath: "transform.rotation.z")
            CATransaction.commit()
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = from
            animation.toValue = from - 2 * .pi
            animation.duration = 360 / state.degreesPerSecond
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: "vinyl-spin")
        } else {
            guard state.isAnimating else { return }
            state.stop(at: Date())
            // Freeze where the layer actually is on screen, not where the
            // animation started, or the disc snaps back a whole turn.
            if let onScreen = layer.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.setValue(onScreen, forKeyPath: "transform.rotation.z")
                CATransaction.commit()
                state.reset(to: -onScreen * 180 / .pi)
            }
            layer.removeAnimation(forKey: "vinyl-spin")
        }
    }
}

#if os(macOS)
private struct SpinningVinylDisc: PlatformViewRepresentable {
    let artworkImage: PlatformImage?
    let discSize: CGFloat
    let spinning: Bool

    func makeNSView(context: Context) -> VinylDiscHost {
        let host = VinylDiscHost(artworkImage: artworkImage, size: discSize)
        host.spin.setSpinning(spinning)
        return host
    }

    func updateNSView(_ host: VinylDiscHost, context: Context) {
        host.update(artworkImage: artworkImage, size: discSize)
        host.spin.setSpinning(spinning)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: VinylDiscHost, context: Context) -> CGSize? {
        CGSize(width: discSize + 6, height: discSize + 6)
    }
}
#else
private struct SpinningVinylDisc: PlatformViewRepresentable {
    let artworkImage: PlatformImage?
    let discSize: CGFloat
    let spinning: Bool

    func makeUIView(context: Context) -> VinylDiscHost {
        let host = VinylDiscHost(artworkImage: artworkImage, size: discSize)
        host.spin.setSpinning(spinning)
        return host
    }

    func updateUIView(_ host: VinylDiscHost, context: Context) {
        host.update(artworkImage: artworkImage, size: discSize)
        host.spin.setSpinning(spinning)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: VinylDiscHost, context: Context) -> CGSize? {
        CGSize(width: discSize + 6, height: discSize + 6)
    }
}
#endif

#if os(macOS)
/// Hosts the record and takes no hits: taps and swipes belong to the SwiftUI
/// gestures wrapped around this representable.
///
/// AppKit anchors a view's backing layer at its origin, so the stage's origin
/// is placed *on the disc's centre* and the record laid out around it:
/// rotating the stage's layer then spins the disc in place, instead of
/// swinging it around the stage's corner.
private final class VinylDiscHost: NSView {
    private let stage = NSView()
    private let record: NSHostingView<VinylRecordView>
    private(set) lazy var spin = DiscSpinController(layer: stage.layer ?? CALayer())

    init(artworkImage: PlatformImage?, size: CGFloat) {
        record = NSHostingView(rootView: VinylRecordView(artworkImage: artworkImage, size: size))
        super.init(frame: .zero)
        wantsLayer = true
        stage.wantsLayer = true
        addSubview(stage)
        stage.addSubview(record)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(artworkImage: PlatformImage?, size: CGFloat) {
        record.rootView = VinylRecordView(artworkImage: artworkImage, size: size)
    }

    override func layout() {
        super.layout()
        stage.frame = CGRect(x: bounds.midX, y: bounds.midY,
                             width: bounds.width, height: bounds.height)
        record.frame = CGRect(x: -bounds.midX, y: -bounds.midY,
                              width: bounds.width, height: bounds.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#else
/// Hosts the record and takes no hits: taps and swipes belong to the SwiftUI
/// gestures wrapped around this representable.
private final class VinylDiscHost: UIView {
    private let record: UIHostingController<VinylRecordView>
    private(set) lazy var spin = DiscSpinController(layer: layer)

    init(artworkImage: PlatformImage?, size: CGFloat) {
        record = UIHostingController(rootView: VinylRecordView(artworkImage: artworkImage, size: size))
        super.init(frame: .zero)
        record.view.backgroundColor = .clear
        addSubview(record.view)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(artworkImage: PlatformImage?, size: CGFloat) {
        record.rootView = VinylRecordView(artworkImage: artworkImage, size: size)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        record.view.frame = bounds
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
#endif
