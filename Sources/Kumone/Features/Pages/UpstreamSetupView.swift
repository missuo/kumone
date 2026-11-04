import SwiftUI

/// Shows ``UpstreamSetupView`` until first-launch setup is done, then `content`.
struct UpstreamGate<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var configured = Upstream.isConfigured || KumonePaths.isOfflineUITest

    var body: some View {
        Group {
            if configured {
                content()
            } else {
                UpstreamSetupView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Upstream.didChange).receive(on: RunLoop.main)) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                configured = Upstream.isConfigured || KumonePaths.isOfflineUITest
            }
        }
    }
}

/// First-launch check: two random arithmetic questions, both required.
struct UpstreamSetupView: View {
    @State private var questions = Upstream.drawQuestions()
    @State private var apiAnswer = ""
    @State private var cdnAnswer = ""
    @FocusState private var focus: Field?

    private enum Field { case api, cdn }

    private var apiCorrect: Bool { questions.api.accepts(apiAnswer) }
    private var cdnCorrect: Bool { questions.cdn.accepts(cdnAnswer) }

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text("开始之前")
                    .font(.largeTitle.bold())
                Text("先做两道算术题，答对才能开始使用。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 16) {
                question(questions.api, answer: $apiAnswer, correct: apiCorrect, field: .api)
                question(questions.cdn, answer: $cdnAnswer, correct: cdnCorrect, field: .cdn)
            }

            Button(action: finish) {
                Text("开始使用")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .disabled(!(apiCorrect && cdnCorrect))
            .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focus = .api }
    }

    private func question(_ question: Upstream.Question,
                          answer: Binding<String>, correct: Bool, field: Field) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: question.prompt)
                .font(.title2.monospacedDigit().weight(.semibold))
            Spacer(minLength: 0)
            TextField("", text: answer)
                .textFieldStyle(.roundedBorder)
                .font(.title3.monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(width: 96)
                .focused($focus, equals: field)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .onSubmit { focus = field == .api ? .cdn : nil }
                .accessibilityLabel(Text(verbatim: question.prompt))
            Image(systemName: correct ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(correct ? Color.green : Color.secondary)
                .font(.title3)
                .accessibilityHidden(true)
        }
    }

    private func finish() {
        guard apiCorrect, cdnCorrect,
              let api = Int(apiAnswer.trimmingCharacters(in: .whitespaces)),
              let cdn = Int(cdnAnswer.trimmingCharacters(in: .whitespaces)) else { return }
        Upstream.configure(.init(api: api, cdn: cdn))
    }
}
