import SwiftUI

struct DownloadProgressIcon: View {
    let progress: Double?
    var size: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(.foreground.opacity(0.2), lineWidth: 1.8)
            if let progress {
                Circle()
                    .trim(from: 0, to: min(1, max(0.025, progress)))
                    .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: progress)
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

/// Keep the completed ring on screen while it fills, then grow the saved icon.
/// Already-downloaded rows start in their final state when first displayed.
struct DownloadButtonIcon: View {
    let isActive: Bool
    let isComplete: Bool
    let progress: Double?
    let size: CGFloat
    let symbolSize: CGFloat
    let completedSymbol: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var completionVisible: Bool

    init(isActive: Bool, isComplete: Bool, progress: Double?, size: CGFloat,
         symbolSize: CGFloat, completedSymbol: String) {
        self.isActive = isActive
        self.isComplete = isComplete
        self.progress = progress
        self.size = size
        self.symbolSize = symbolSize
        self.completedSymbol = completedSymbol
        _completionVisible = State(initialValue: isComplete)
    }

    var body: some View {
        ZStack {
            if isComplete && completionVisible {
                Image(systemName: completedSymbol)
                    .font(.system(size: symbolSize, weight: .medium))
                    .transition(reduceMotion ? .identity : .scale(scale: 0.35).combined(with: .opacity))
            } else if isActive || isComplete {
                DownloadProgressIcon(progress: isComplete ? 1 : progress, size: size)
                    .transition(reduceMotion ? .identity : .scale(scale: 0.35).combined(with: .opacity))
            } else {
                Image(systemName: "arrow.down")
                    .font(.system(size: symbolSize, weight: .medium))
            }
        }
        .frame(width: size, height: size)
        .task(id: isComplete) {
            guard isComplete else { completionVisible = false; return }
            guard !completionVisible else { return }
            if !reduceMotion {
                do { try await Task.sleep(for: .milliseconds(180)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) {
                completionVisible = true
            }
        }
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
