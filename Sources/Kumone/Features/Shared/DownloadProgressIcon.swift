import SwiftUI

struct DownloadProgressIcon: View {
    let progress: Double?
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().stroke(.foreground.opacity(0.2), lineWidth: 1.8)
            if let progress {
                Circle()
                    .trim(from: 0, to: min(1, max(0.025, progress)))
                    .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: progress)
            } else {
                DownloadSpinningArc()
            }
            Image(systemName: "stop.fill")
                .font(.system(size: size * 0.4, weight: .semibold))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct DownloadSpinningArc: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .rotationEffect(.degrees(rotating && !reduceMotion ? 270 : -90))
            .animation(reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false), value: rotating)
            .onAppear { rotating = true }
    }
}
