import SwiftUI

/// High-fidelity programmatic vector vinyl record disc.
/// Features dense micro-grooves, radial light refraction, specular sheen sweep,
/// beveled vinyl rims, and refined center circular artwork.
public struct VinylRecordView: View {
    public let artworkImage: PlatformImage?
    public let size: CGFloat

    public init(artworkImage: PlatformImage?, size: CGFloat = 280) {
        self.artworkImage = artworkImage
        self.size = size
    }

    public var body: some View {
        let discDiameter = size
        let labelDiameter = discDiameter * 0.64 // Vintage vinyl label ratio
        let spindleHoleDiameter = max(7, discDiameter * 0.032)

        return ZStack {
            // MARK: 1. Outer Turntable Rubber Platter Underlay (转盘防滑垫底盘)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.06), Color(white: 0.02)],
                        center: .center,
                        startRadius: discDiameter * 0.3,
                        endRadius: discDiameter * 0.5
                    )
                )
                .frame(width: discDiameter + 6, height: discDiameter + 6)
                .shadow(color: .black.opacity(0.45), radius: max(16, discDiameter * 0.08), x: 0, y: discDiameter * 0.04)
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)

            // MARK: 2. Heavy Glossy Vinyl Disc Body (黑胶本体与边缘倒角)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(white: 0.14),
                            Color(white: 0.08),
                            Color(white: 0.05),
                            Color(white: 0.03)
                        ],
                        center: .center,
                        startRadius: discDiameter * 0.25,
                        endRadius: discDiameter * 0.5
                    )
                )
                .frame(width: discDiameter, height: discDiameter)
                .overlay {
                    // Outer beveled edge highlight
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.25),
                                    Color.white.opacity(0.04),
                                    Color.white.opacity(0.18),
                                    Color.black.opacity(0.6)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                }

            // MARK: 3. High-Frequency Vinyl Micro-Grooves & Radial Diffraction (径向微光与高密音轨)
            Circle()
                .fill(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Color(white: 0.06),
                            Color(white: 0.18),
                            Color(white: 0.05),
                            Color(white: 0.22),
                            Color(white: 0.07),
                            Color(white: 0.16),
                            Color(white: 0.05),
                            Color(white: 0.20),
                            Color(white: 0.06),
                            Color(white: 0.18),
                            Color(white: 0.06)
                        ]),
                        center: .center
                    )
                )
                .frame(width: discDiameter - 4, height: discDiameter - 4)
                .opacity(0.9)

            // 18 Dense Concentric Audio Grooves (细腻刻纹)
            ForEach(0..<18, id: \.self) { i in
                let factor = 0.68 + (Double(i) / 17.0) * 0.29
                let isMajorTrack = (i % 4 == 0)
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isMajorTrack ? 0.14 : 0.06),
                                Color.black.opacity(0.4),
                                Color.white.opacity(isMajorTrack ? 0.09 : 0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isMajorTrack ? 0.8 : 0.45
                    )
                    .frame(width: discDiameter * factor, height: discDiameter * factor)
            }

            // Lead-in Outer Groove (外圈入轨引导槽)
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 0.9)
                .frame(width: discDiameter * 0.98, height: discDiameter * 0.98)

            // Run-out Inner Groove (内圈死区/导光槽)
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.20), Color.black.opacity(0.5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
                .frame(width: discDiameter * 0.665, height: discDiameter * 0.665)

            // MARK: 4. Dual-Lobe Specular Sheen Sweep (逼真的双扇形镜面扫光)
            Circle()
                .fill(
                    AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: Color.white.opacity(0.02), location: 0.08),
                            .init(color: Color.white.opacity(0.18), location: 0.14),
                            .init(color: Color(red: 0.85, green: 0.95, blue: 1.0).opacity(0.24), location: 0.17),
                            .init(color: Color.white.opacity(0.18), location: 0.20),
                            .init(color: Color.white.opacity(0.02), location: 0.26),
                            .init(color: .clear, location: 0.34),

                            .init(color: .clear, location: 0.50),
                            .init(color: Color.white.opacity(0.02), location: 0.58),
                            .init(color: Color.white.opacity(0.18), location: 0.64),
                            .init(color: Color(red: 0.85, green: 0.95, blue: 1.0).opacity(0.24), location: 0.67),
                            .init(color: Color.white.opacity(0.18), location: 0.70),
                            .init(color: Color.white.opacity(0.02), location: 0.76),
                            .init(color: .clear, location: 0.84),
                            .init(color: .clear, location: 1.0)
                        ]),
                        center: .center,
                        angle: .degrees(35)
                    )
                )
                .frame(width: discDiameter - 2, height: discDiameter - 2)
                .blendMode(.screen)
                .allowsHitTesting(false)

            // MARK: 5. Center Label & Album Artwork (精美唱片中心纸标与主轴孔)
            ZStack {
                // Label outer bevel frame
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.16), Color(white: 0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: labelDiameter + 6, height: labelDiameter + 6)
                    .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)

                // Album Artwork Cover
                Group {
                    if let artworkImage {
                        Image(platformImage: artworkImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            LinearGradient(
                                colors: [Color(white: 0.22), Color(white: 0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: "music.note")
                                .font(.system(size: labelDiameter * 0.35, weight: .light))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
                .frame(width: labelDiameter, height: labelDiameter)
                .clipShape(Circle())
                .overlay {
                    // Paper label edge ring
                    Circle()
                        .strokeBorder(Color.black.opacity(0.45), lineWidth: 1.5)
                }

                // Inner label fine gold-embossed ring (复古装饰金线)
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.28), Color.white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
                    .frame(width: labelDiameter * 0.86, height: labelDiameter * 0.86)

                // Central Chrome Spindle Grommet (金属主轴孔环)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(white: 0.95),
                                Color(white: 0.65),
                                Color(white: 0.90),
                                Color(white: 0.40)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: spindleHoleDiameter * 2.4, height: spindleHoleDiameter * 2.4)
                    .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)

                Circle()
                    .stroke(Color.white.opacity(0.6), lineWidth: 0.6)
                    .frame(width: spindleHoleDiameter * 2.4, height: spindleHoleDiameter * 2.4)

                // Spindle Center Hole
                Circle()
                    .fill(Color(white: 0.04))
                    .frame(width: spindleHoleDiameter, height: spindleHoleDiameter)
                    .overlay {
                        Circle().stroke(Color.black.opacity(0.9), lineWidth: 0.8)
                    }
            }
        }
        .frame(width: discDiameter + 6, height: discDiameter + 6)
    }
}
