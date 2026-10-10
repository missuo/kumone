import QuartzCore
import SwiftUI

/// Vector mechanical tonearm (唱臂与唱针) matching vintage / NetEase turntable styling.
/// Features metallic pivot base, curved tonearm tube, counterweight, headshell, cartridge, stylus tip,
/// and smooth engaging/disengaging rotation animation.
public struct VinylTonearmView: View {
    public let isPlaying: Bool
    public let height: CGFloat
    public let reduceMotion: Bool
    @ObservedObject private var windowVisibility = MainWindowVisibility.shared

    public init(isPlaying: Bool, height: CGFloat = 175, reduceMotion: Bool = false) {
        self.isPlaying = isPlaying
        self.height = height
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        // Base width proportional to height
        let width = height * 0.58
        let pivotSize = width * 0.46

        ZStack(alignment: .top) {
            // 1. Static Pivot Base (固定底座)
            pivotBase(size: pivotSize)
                .zIndex(3)

            // 2. Rotating Arm Assembly (可旋转的臂杆总成)
            EngagingTonearm(
                arm: armAssembly(width: width, height: height),
                engaged: isPlaying,
                wobbling: isPlaying && !reduceMotion && windowVisibility.isVisible,
                animated: !reduceMotion,
                width: width,
                height: height,
                pivotY: pivotSize * 0.5
            )
            .shadow(color: .black.opacity(0.4), radius: 6, x: -3, y: 5)
            .zIndex(2)
        }
        .frame(width: width, height: height, alignment: .top)
    }

    /// The arm's idle wobble, sampled by the layer animation the arm now runs
    /// on. `seconds` is an offset into the wobble's own timeline: the two
    /// sines meet again after 35.2 s (3.2 s × 11 == 1.1 s × 32), which is what
    /// makes the looping layer animation seamless.
    static func wobbleDegrees(at seconds: Double) -> Double {
        let harmonic1 = sin(seconds * 2.0 * .pi / 3.2) * 0.20
        let harmonic2 = sin(seconds * 2.0 * .pi / 1.1 + 0.6) * 0.08
        return harmonic1 + harmonic2
    }

    // MARK: - Pivot Base View

    private func pivotBase(size: CGFloat) -> some View {
        ZStack {
            // Outer drop shadow
            Circle()
                .fill(Color.black.opacity(0.5))
                .frame(width: size * 1.1, height: size * 1.1)
                .blur(radius: 3)
                .offset(y: 2)

            // Outer metallic rim (拉丝金属外环)
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.82), Color(white: 0.35), Color(white: 0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.5), lineWidth: 0.8)
                }

            // Dark inner disc (暗色内圈台架)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.24), Color(white: 0.08)],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.42
                    )
                )
                .frame(width: size * 0.80, height: size * 0.80)

            // Inner pivot chrome cap (中心高光轴承盖)
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.95), Color(white: 0.55), Color(white: 0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size * 0.40, height: size * 0.40)
                .shadow(color: .black.opacity(0.4), radius: 1, y: 1)

            // Center bearing screw (中心紧固螺栓)
            Circle()
                .fill(Color(white: 0.12))
                .frame(width: size * 0.14, height: size * 0.14)
        }
        .frame(width: size, height: size)
    }

    // MARK: - Rotating Arm Assembly

    private func armAssembly(width: CGFloat, height: CGFloat) -> some View {
        let pivotY = (width * 0.46) * 0.5
        let tubeWidth: CGFloat = max(3.5, width * 0.058)

        return ZStack(alignment: .top) {
            // Counterweight behind the pivot (后置金属配重坨)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.75), Color(white: 0.25), Color(white: 0.65)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: tubeWidth * 2.6, height: height * 0.15)
                .offset(y: -height * 0.08)

            // Shadow behind the entire arm
            TonearmPath()
                .stroke(Color.black.opacity(0.35), lineWidth: tubeWidth * 1.5)
                .blur(radius: 2.5)
                .offset(x: 2, y: 3)

            // Curved Metallic Tonearm Tube (S型高光金属臂杆)
            TonearmPath()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(white: 0.98),
                            Color(white: 0.55),
                            Color(white: 0.92),
                            Color(white: 0.40)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: tubeWidth, lineCap: .round, lineJoin: .round)
                )

            // Headshell & Cartridge at the bottom-left of the arm curve (唱头架与唱针)
            headshellAndCartridge(width: width, height: height)
        }
        .frame(width: width, height: height)
        .offset(y: pivotY)
    }

    private func headshellAndCartridge(width: CGFloat, height: CGFloat) -> some View {
        let headWidth = width * 0.24
        let headHeight = height * 0.22

        return ZStack {
            // Headshell plate (angular cover)
            RoundedRectangle(cornerRadius: 2.5)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.32), Color(white: 0.10)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: headWidth, height: headHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: 2.5)
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
                }

            // Finger lift handle on headshell side (唱头提手把柄)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.85), Color(white: 0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 2.5, height: headHeight * 0.45)
                .offset(x: headWidth * 0.52, y: -headHeight * 0.1)

            // Cartridge body & Stylus needle indicator (红白经典唱头与银色探针)
            VStack(spacing: 0) {
                Spacer()
                // Red cartridge band
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.92, green: 0.22, blue: 0.22), Color(red: 0.55, green: 0.08, blue: 0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: headWidth * 0.65, height: 4.5)

                // Silver stylus needle point (探针针尖)
                Triangle()
                    .fill(Color(white: 0.95))
                    .frame(width: 3, height: 3.5)
                    .offset(y: 1)
            }
        }
        .frame(width: headWidth, height: headHeight)
        .rotationEffect(.degrees(24))
        .position(x: width * 0.31, y: height * 0.74)
    }
}

// MARK: - Tonearm S-Curve Path

private struct TonearmPath: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let startPoint = CGPoint(x: rect.width * 0.5, y: 0)
        let midPoint1 = CGPoint(x: rect.width * 0.58, y: rect.height * 0.28)
        let midPoint2 = CGPoint(x: rect.width * 0.42, y: rect.height * 0.55)
        let endPoint = CGPoint(x: rect.width * 0.31, y: rect.height * 0.74)

        path.move(to: startPoint)
        path.addCurve(
            to: midPoint1,
            control1: CGPoint(x: rect.width * 0.52, y: rect.height * 0.1),
            control2: CGPoint(x: rect.width * 0.58, y: rect.height * 0.2)
        )
        path.addCurve(
            to: midPoint2,
            control1: CGPoint(x: rect.width * 0.58, y: rect.height * 0.38),
            control2: CGPoint(x: rect.width * 0.45, y: rect.height * 0.48)
        )
        path.addCurve(
            to: endPoint,
            control1: CGPoint(x: rect.width * 0.38, y: rect.height * 0.62),
            control2: CGPoint(x: rect.width * 0.33, y: rect.height * 0.70)
        )
        return path
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Arm motion on the layer

/// Drives the arm's layer: a spring for the engage/disengage swing, and an
/// additive keyframe wobble while the record plays. The `TimelineView` this
/// replaces re-evaluated the whole arm — and the page's layout around it —
/// on every display frame for that ±0.28° shimmer (#128 performance work).
private final class TonearmMotionController {
    private static let restedDegrees: Double = 0
    private static let parkedDegrees: Double = -32

    private let layer: CALayer
    private var engaged: Bool
    private var wobbling = false

    init(layer: CALayer, engaged: Bool) {
        self.layer = layer
        self.engaged = engaged
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(Self.zRotation(engaged: engaged), forKeyPath: "transform.rotation.z")
        CATransaction.commit()
    }

    func setEngaged(_ engaged: Bool, animated: Bool) {
        guard engaged != self.engaged else { return }
        self.engaged = engaged
        let target = Self.zRotation(engaged: engaged)
        // Retarget from what is on screen, not from the model: a drag released
        // mid-swing must reverse smoothly rather than jump to the far end.
        let from = layer.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double
            ?? layer.value(forKeyPath: "transform.rotation.z") as? Double ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(target, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
        guard animated else { return }
        // CASpringAnimation parameters converted from the SwiftUI spring this
        // replaces (response 0.48, damping fraction 0.74, mass 1).
        let spring = CASpringAnimation(keyPath: "transform.rotation.z")
        spring.mass = 1
        spring.stiffness = 171.5
        spring.damping = 19.4
        spring.initialVelocity = 0
        spring.fromValue = from
        spring.toValue = target
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "tonearm-engage")
    }

    func setWobbling(_ wobbling: Bool) {
        guard wobbling != self.wobbling else { return }
        self.wobbling = wobbling
        guard wobbling else {
            layer.removeAnimation(forKey: "tonearm-wobble")
            return
        }
        // One seamless period of `wobbleDegrees`, sampled. Additive: the
        // shimmer rides on the resting angle the spring sets instead of
        // replacing it.
        let period = 35.2
        let step = 0.1
        let samples = Int(period / step) + 1
        let values = (0..<samples).map { index in
            -VinylTonearmView.wobbleDegrees(at: Double(index) * step) * .pi / 180
        }
        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = values
        animation.duration = period
        animation.repeatCount = .infinity
        animation.isAdditive = true
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(animation, forKey: "tonearm-wobble")
    }

    /// Core Animation measures angles the other way round from SwiftUI, so the
    /// SwiftUI-side degrees (`-32` parks the arm away from the record) arrive
    /// on the layer negated.
    private static func zRotation(engaged: Bool) -> Double {
        -(engaged ? restedDegrees : parkedDegrees) * .pi / 180
    }
}

#if os(macOS)
private struct EngagingTonearm<Content: View>: PlatformViewRepresentable {
    let arm: Content
    let engaged: Bool
    let wobbling: Bool
    let animated: Bool
    let width: CGFloat
    let height: CGFloat
    let pivotY: CGFloat

    func makeNSView(context: Context) -> TonearmHost<Content> {
        TonearmHost(arm: arm, engaged: engaged, wobbling: wobbling,
                    width: width, height: height, pivotY: pivotY)
    }

    func updateNSView(_ host: TonearmHost<Content>, context: Context) {
        host.update(arm: arm, width: width, height: height, pivotY: pivotY)
        host.motion.setEngaged(engaged, animated: animated)
        host.motion.setWobbling(wobbling)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TonearmHost<Content>, context: Context) -> CGSize? {
        CGSize(width: width, height: height)
    }
}

/// Holds the arm inside a stage whose origin sits *on the arm's pivot*: AppKit
/// anchors a view's backing layer at its origin, so the pivot is placed at the
/// stage's origin and the arm at negative coordinates — the layer rotation
/// then swings the arm around that point instead of the stage's corner.
private final class TonearmHost<Content: View>: NSView {
    private let arm: NSHostingView<Content>
    private let stage = NSView()
    private var width: CGFloat
    private var height: CGFloat
    private var pivotY: CGFloat
    private(set) var motion: TonearmMotionController!

    init(arm: Content, engaged: Bool, wobbling: Bool,
         width: CGFloat, height: CGFloat, pivotY: CGFloat) {
        self.arm = NSHostingView(rootView: arm)
        self.width = width
        self.height = height
        self.pivotY = pivotY
        super.init(frame: .zero)
        stage.wantsLayer = true
        addSubview(stage)
        stage.addSubview(self.arm)
        motion = TonearmMotionController(layer: stage.layer ?? CALayer(), engaged: engaged)
        motion.setWobbling(wobbling)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(arm: Content, width: CGFloat, height: CGFloat, pivotY: CGFloat) {
        self.arm.rootView = arm
        self.width = width
        self.height = height
        self.pivotY = pivotY
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // The arm's pivot is given from the top; AppKit layers measure it from
        // the bottom-left, where their anchor sits.
        stage.frame = CGRect(x: bounds.midX, y: bounds.height - pivotY,
                             width: width, height: height)
        arm.frame = CGRect(x: -width / 2, y: -(bounds.height - pivotY),
                           width: width, height: height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

#else
private struct EngagingTonearm<Content: View>: PlatformViewRepresentable {
    let arm: Content
    let engaged: Bool
    let wobbling: Bool
    let animated: Bool
    let width: CGFloat
    let height: CGFloat
    let pivotY: CGFloat

    func makeUIView(context: Context) -> TonearmHost<Content> {
        TonearmHost(arm: arm, engaged: engaged, wobbling: wobbling,
                    width: width, height: height, pivotY: pivotY)
    }

    func updateUIView(_ host: TonearmHost<Content>, context: Context) {
        host.update(arm: arm, width: width, height: height, pivotY: pivotY)
        host.motion.setEngaged(engaged, animated: animated)
        host.motion.setWobbling(wobbling)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TonearmHost<Content>, context: Context) -> CGSize? {
        CGSize(width: width, height: height)
    }
}

/// Same square stage as the macOS host — see above.
private final class TonearmHost<Content: View>: UIView {
    private let armController: UIHostingController<Content>
    private let stage = UIView()
    private var width: CGFloat
    private var height: CGFloat
    private var pivotY: CGFloat
    private(set) var motion: TonearmMotionController!

    init(arm: Content, engaged: Bool, wobbling: Bool,
         width: CGFloat, height: CGFloat, pivotY: CGFloat) {
        armController = UIHostingController(rootView: arm)
        self.width = width
        self.height = height
        self.pivotY = pivotY
        super.init(frame: .zero)
        armController.view.backgroundColor = .clear
        addSubview(stage)
        stage.addSubview(armController.view)
        motion = TonearmMotionController(layer: stage.layer, engaged: engaged)
        motion.setWobbling(wobbling)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(arm: Content, width: CGFloat, height: CGFloat, pivotY: CGFloat) {
        armController.rootView = arm
        self.width = width
        self.height = height
        self.pivotY = pivotY
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = Self.stageSide(width: width, height: height, pivotY: pivotY)
        stage.frame = CGRect(x: bounds.midX - side / 2, y: pivotY - side / 2,
                             width: side, height: side)
        armController.view.frame = CGRect(x: side / 2 - width / 2, y: side / 2 - pivotY,
                                          width: width, height: height)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    private static func stageSide(width: CGFloat, height: CGFloat, pivotY: CGFloat) -> CGFloat {
        let reach = hypot(width / 2, max(pivotY, height - pivotY))
        return (reach + 12).rounded(.up) * 2
    }
}
#endif

