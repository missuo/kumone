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
            TimelineView(.animation(
                paused: !isPlaying || reduceMotion || !windowVisibility.isVisible
            )) { timeline in
                let wobble = wobbleDegrees(at: timeline.date)
                armAssembly(width: width, height: height)
                    .rotationEffect(
                        .degrees(rotationAngle + wobble),
                        anchor: UnitPoint(x: 0.5, y: pivotSize * 0.5 / height)
                    )
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.74, blendDuration: 0.08),
                value: isPlaying
            )
            .shadow(color: .black.opacity(0.4), radius: 6, x: -3, y: 5)
            .zIndex(2)
        }
        .frame(width: width, height: height, alignment: .top)
    }

    private var rotationAngle: Double {
        // Playing: resting onto outer track (0°); Paused: lifted and parked away (-32°)
        isPlaying ? 0.0 : -32.0
    }

    private func wobbleDegrees(at date: Date) -> Double {
        guard isPlaying, !reduceMotion else { return 0 }
        let seconds = date.timeIntervalSinceReferenceDate
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
