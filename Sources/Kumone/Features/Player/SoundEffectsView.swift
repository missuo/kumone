#if os(iOS)
import SwiftUI

struct SoundEffectsButton: View {
    @EnvironmentObject private var settings: SettingsManager

    let action: () -> Void
    var diameter: CGFloat = 44
    var glyphSize: CGFloat = 17
    var showsBackground = true

    var body: some View {
        Menu {
            // A picker gives the menu the system checkmark on the active preset.
            Picker("音效", selection: Binding(
                get: { settings.soundEffectPreset },
                set: { settings.selectSoundEffect($0) }
            )) {
                ForEach(SoundEffectPreset.allCases.filter { $0 != .custom }) { preset in
                    Label(preset.displayName, systemImage: preset.systemImage)
                        .tag(preset)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Button(action: action) {
                Label("均衡器…", systemImage: "slider.vertical.3")
            }
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: glyphSize, weight: .medium))
                .foregroundStyle(
                    settings.soundEffectPreset == .original
                        ? .white.opacity(0.76)
                        : Theme.accent)
                .frame(width: diameter, height: diameter)
                .background {
                    if showsBackground {
                        Circle().fill(.white.opacity(0.08))
                    }
                }
                .contentShape(Circle())
        }
        .menuOrder(.fixed)
        .buttonStyle(.pressable)
        .accessibilityLabel("音效")
        .accessibilityValue(settings.soundEffectPreset.displayName)
        .accessibilityIdentifier("soundEffectsButton")
    }
}

enum SoundEffectsSection: String, CaseIterable, Identifiable {
    case effects
    case equalizer

    var id: String { rawValue }
}

private struct SoundEffectsPresentationModifier: ViewModifier {
    @Binding var isPresented: Bool
    @ObservedObject var settings: SettingsManager

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            NavigationStack {
                SoundEffectsPage(initialSection: .equalizer)
                    .environmentObject(settings)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { isPresented = false }
                                .tint(Color.primary)
                        }
                    }
            }
        }
    }
}

extension View {
    func soundEffectsPresentation(
        isPresented: Binding<Bool>,
        settings: SettingsManager
    ) -> some View {
        modifier(SoundEffectsPresentationModifier(
            isPresented: isPresented,
            settings: settings
        ))
    }
}

struct SoundEffectsPage: View {
    var initialSection: SoundEffectsSection = .effects

    var body: some View {
        SoundEffectsContent(
            initialSection: initialSection
        )
            .accessibilityIdentifier("soundEffectsPage")
    }
}

private struct SoundEffectsContent: View {
    @EnvironmentObject private var settings: SettingsManager
    @ObservedObject private var spectrum = AudioSpectrum.shared
    @State private var selectedSection: SoundEffectsSection

    private let standardPresets = SoundEffectPreset.allCases.filter { $0 != .custom }

    init(initialSection: SoundEffectsSection) {
        _selectedSection = State(initialValue: initialSection)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedSection) {
                Text("预设").tag(SoundEffectsSection.effects)
                Text("均衡器").tag(SoundEffectsSection.equalizer)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .accessibilityIdentifier("soundEffectsSectionPicker")

            switch selectedSection {
            case .effects:
                effectsContent
            case .equalizer:
                equalizerContent
            }
        }
        .background(soundEffectsBackground)
        .navigationTitle("音效")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.easeInOut(duration: 0.2), value: settings.soundEffectPreset)
        // No accent-colored text on these pages: the app-wide accent tint
        // would turn every plain button red. Controls that should carry the
        // accent (the selection checkmark, the switch, the band handles) set
        // it themselves.
        .tint(Color.primary)
    }

    private var effectsContent: some View {
        List {
            if spectrum.tapState == .preparing || spectrum.tapState == .untappable {
                Section {
                    availabilityNotice
                }
            }

            Section {
                ForEach(standardPresets) { preset in
                    presetRow(preset)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var equalizerContent: some View {
        GeometryReader { geometry in
            ScrollView {
                SoundEffectsEqualizerEditor(
                    isEnabled: settings.isCustomEqualizerEnabled,
                    availableHeight: max(geometry.size.height - 22, 520)
                )
                .padding(.horizontal, 20)
                .padding(.top, 22)
            }
        }
    }

    @ViewBuilder
    private var availabilityNotice: some View {
        switch spectrum.tapState {
        case .idle, .tapped:
            EmptyView()
        case .preparing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在准备当前音源的音效处理…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .untappable:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("当前音源暂不支持音效，将保持原声播放；所选方案会在下一首可处理歌曲自动生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A plain settings row: tapping it selects the preset, and the selected
    /// one carries the checkmark.
    private func presetRow(_ preset: SoundEffectPreset) -> some View {
        let isSelected = settings.soundEffectPreset == preset
        return Button {
            settings.selectSoundEffect(preset)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: preset.systemImage)
                    .font(.body)
                    .symbolRenderingMode(.hierarchical)
                    // Concrete colors: in a list the button's tint would
                    // otherwise recolor the hierarchical styles.
                    .foregroundStyle(Color.secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.displayName)
                        .foregroundStyle(Color.primary)
                    Text(preset.effectDescription)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preset.displayName)
        .accessibilityValue(preset.effectDescription)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("soundEffectPreset.\(preset.rawValue)")
    }

    private var soundEffectsBackground: some View {
        Color(uiColor: .systemGroupedBackground)
            .ignoresSafeArea()
    }
}

private struct SoundEffectsEqualizerEditor: View {
    @EnvironmentObject private var settings: SettingsManager

    let isEnabled: Bool
    let availableHeight: CGFloat

    var body: some View {
        // Reserve only the space actually consumed by the header, labels and
        // stack spacing. The response graph then expands into every remaining
        // point instead of leaving an empty lower half on taller devices.
        let flexibleHeight = max(availableHeight - 140, 380)
        let sliderHeight = min(max(flexibleHeight * 0.58, 220), 360)

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("均衡器")
                        .font(.headline)
                    Text("拖动频段即可实时试听，设置会自动保存")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 16) {
                    Button("重置") { settings.resetCustomEqualizer() }
                        .font(.subheadline.weight(.semibold))
                        .disabled(!isEnabled)

                    Toggle("均衡器", isOn: Binding(
                        get: { settings.isCustomEqualizerEnabled },
                        set: { settings.setCustomEqualizerEnabled($0) }
                    ))
                    .labelsHidden()
                    .tint(Theme.accent)
                    .accessibilityValue(isEnabled ? "已开启" : "已关闭")
                    .accessibilityIdentifier("equalizerEnabledSwitch")
                }
                .padding(.top, 2)
            }

            HStack(alignment: .top, spacing: 6) {
                VStack {
                    Text("+12")
                    Spacer()
                    Text("0")
                    Spacer()
                    Text("−12")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, height: sliderHeight)
                .padding(.top, 30)

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(0..<EqualizerConfiguration.bandCount, id: \.self) { index in
                            EqualizerBandControl(
                                index: index,
                                value: settings.customEqualizerGains[index],
                                sliderHeight: sliderHeight,
                                onChange: { settings.updateCustomEqualizerGain(at: index, to: $0) }
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .equalizerHorizontalBounce()
            }
            // Keep the controls draggable while bypassed: the first value
            // change promotes the saved curve to the active custom preset.
            .opacity(isEnabled ? 1 : 0.72)
            .accessibilityIdentifier("customEqualizer")

            EqualizerResponseCurve(
                gains: settings.customEqualizerGains,
                isEnabled: isEnabled)
                .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
                .accessibilityIdentifier("equalizerResponseCurve")
        }
        .frame(maxWidth: .infinity)
        .frame(height: availableHeight, alignment: .top)
    }
}

private extension View {
    @ViewBuilder
    func equalizerHorizontalBounce() -> some View {
        if #available(iOS 16.4, *) {
            scrollBounceBehavior(.always, axes: .horizontal)
        } else {
            self
        }
    }
}

private struct EqualizerResponseCurve: View {
    let gains: [Float]
    let isEnabled: Bool

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }

            var response = Path()
            let pointCount = 160
            for point in 0..<pointCount {
                let fraction = Double(point) / Double(pointCount - 1)
                let frequency = 20 * pow(1_000, fraction)
                let value = EqualizerMath.responseDB(
                    gains: gains, frequency: frequency, sampleRate: 48_000)
                let clamped = min(max(value, -12), 12)
                let x = size.width * CGFloat(fraction)
                let y = size.height * CGFloat((12 - clamped) / 24)
                if point == 0 {
                    response.move(to: CGPoint(x: x, y: y))
                } else {
                    response.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(
                response,
                with: .color(isEnabled ? Theme.accent : .secondary),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("实时频响曲线")
        .accessibilityValue(isEnabled ? "已开启" : "已关闭")
    }
}

private struct EqualizerBandControl: View {
    private enum DragAxis {
        case horizontal
        case vertical
    }

    let index: Int
    let value: Float
    var sliderHeight: CGFloat = 142
    let onChange: (Float) -> Void

    @State private var dragAxis: DragAxis?

    var body: some View {
        VStack(spacing: 8) {
            Text(formattedGain)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42)

            GeometryReader { geometry in
                let height = geometry.size.height
                let y = position(for: value, height: height)
                ZStack {
                    Capsule()
                        .fill(.primary.opacity(0.15))
                        .frame(width: 5)
                    Rectangle()
                        .fill(.primary.opacity(0.22))
                        .frame(width: 18, height: 1)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 16, height: 7)
                        .shadow(color: Theme.accent.opacity(0.35), radius: 5)
                        .frame(width: 34, height: 44)
                        .contentShape(Rectangle())
                        .position(x: geometry.size.width / 2, y: y)
                        .simultaneousGesture(
                            DragGesture(
                                minimumDistance: 8,
                                coordinateSpace: .named("equalizerTrack.\(index)")
                            )
                            .onChanged { gesture in
                                if dragAxis == nil {
                                    let horizontalDistance = abs(gesture.translation.width)
                                    let verticalDistance = abs(gesture.translation.height)
                                    dragAxis = verticalDistance >= horizontalDistance
                                        ? .vertical
                                        : .horizontal
                                }

                                if dragAxis == .vertical {
                                    update(locationY: gesture.location.y, height: height)
                                }
                            }
                            .onEnded { gesture in
                                if dragAxis == .vertical {
                                    update(locationY: gesture.location.y, height: height)
                                }
                                dragAxis = nil
                            }
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .coordinateSpace(name: "equalizerTrack.\(index)")
            }
            .frame(width: 34, height: sliderHeight)

            Text(EqualizerConfiguration.frequencyLabel(at: index))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary.opacity(0.72))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(EqualizerConfiguration.frequencyLabel(at: index)) Hz")
        .accessibilityValue(formattedGain)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(value + 1, EqualizerConfiguration.gainRange.upperBound))
            case .decrement: onChange(max(value - 1, EqualizerConfiguration.gainRange.lowerBound))
            @unknown default: break
            }
        }
        .accessibilityIdentifier("equalizerBand.\(index)")
    }

    private var formattedGain: String {
        let rounded = Int(value.rounded())
        if rounded > 0 { return "+\(rounded) dB" }
        return "\(rounded) dB"
    }

    private func position(for value: Float, height: CGFloat) -> CGFloat {
        let range = EqualizerConfiguration.gainRange
        let fraction = CGFloat((range.upperBound - value) / (range.upperBound - range.lowerBound))
        return min(max(fraction * height, 4), height - 4)
    }

    private func update(locationY: CGFloat, height: CGFloat) {
        guard height > 0 else { return }
        let fraction = Float(min(max(locationY / height, 0), 1))
        let range = EqualizerConfiguration.gainRange
        let raw = range.upperBound - fraction * (range.upperBound - range.lowerBound)
        onChange(raw.rounded())
    }
}
#endif
