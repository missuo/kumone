import SwiftUI

/// Public SwiftUI progress styling, matching the segmented storage indicator
/// in system settings. There is no private Settings-framework dependency.
struct StorageCapacityBar: View {
    let capacity: DeviceStorageCapacity
    let appBytes: Int64
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: Double(capacity.used), total: Double(max(1, capacity.total)))
                .progressViewStyle(SegmentedStorageProgressStyle(fractions: capacity.fractions(appBytes: appBytes), height: height))
                .accessibilityLabel("设备存储占用")
                .accessibilityValue(Text("已用 \(format(capacity.used))，共 \(format(capacity.total))"))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { legend }
                VStack(alignment: .leading, spacing: 6) { legend }
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var legend: some View {
        item("Kumone", color: .red)
        item("其他已用", color: .gray.opacity(0.55))
        item("可用", color: .primary.opacity(0.12))
    }

    private func item(_ title: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
        }
    }

    private func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

private struct SegmentedStorageProgressStyle: ProgressViewStyle {
    let fractions: [Double]
    let height: CGFloat
    private let colors: [Color] = [.red, .gray.opacity(0.45), .primary.opacity(0.04)]

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(fractions.indices, id: \.self) { index in
                    colors[index]
                        .frame(width: geometry.size.width * fractions[index])
                        .overlay(alignment: .trailing) {
                            if index < fractions.count - 1, fractions[index] > 0 {
                                Rectangle().fill(.background).frame(width: min(1, geometry.size.width * fractions[index] / 2))
                            }
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
        }
        .frame(height: height)
    }
}
