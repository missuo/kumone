import CoreImage.CIFilterBuiltins
import SwiftUI

struct LoginSheet: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case qr = "扫码登录"
        case sms = "手机验证码"
        case cookie = "Cookie 登录"

        var id: String { rawValue }
    }

    private enum Phase: Equatable {
        case loading
        case waiting          // 801
        case scanned(String)  // 802, nickname
        case expired          // 800
        case success
        case failed(String)
    }

    @State private var mode: Mode = .qr
    @State private var phase: Phase = .loading
    @State private var qrImage: PlatformImage?
    @State private var unikey: String?
    @State private var pollTask: Task<Void, Never>?

    // SMS login
    @State private var phone = ""
    @State private var code = ""
    @State private var smsCooldown = 0
    @State private var smsSending = false
    @State private var smsLoggingIn = false
    @State private var smsMessage: String?
    @State private var cooldownTask: Task<Void, Never>?
    @State private var cookieHeader = ""
    @State private var cookieMessage: String?
    @State private var cookieTask: Task<Void, Never>?
    @State private var cookieAttempt: UUID?
    @State private var syncedLoggingIn = false
    @State private var isPresented = false

    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("登录账号")
                    .font(.title3.weight(.semibold))
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                .disabled(smsLoggingIn || syncedLoggingIn)
                .padding(.top, 6)
            }
            .padding(.top, 28)

            SyncedLoginButtons(onStart: {
                syncedLoggingIn = true
                cancelCookieLogin()
                pollTask?.cancel()
            }, onFinished: { signedIn in
                syncedLoggingIn = false
                if signedIn { dismiss() }
                else if mode == .qr, !account.isLoggedIn { startLogin(reusingKey: true) }
            })
            .disabled(smsLoggingIn || cookieAttempt != nil)
            .padding(.horizontal, 24)

            switch mode {
            case .qr:
                qrSection
            case .sms:
                smsSection
            case .cookie:
                cookieSection
            }

            Button("取消") {
                isPresented = false
                cancelCookieLogin()
                pollTask?.cancel()
                dismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .padding(.bottom, 20)
        }
        .frame(width: 320)
        .overlay(alignment: .top) {
            if let toast = toasts.current { ToastView(toast: toast).padding(.top, 8) }
        }
        .onAppear {
            isPresented = true
            startLogin()
        }
        .onDisappear {
            isPresented = false
            cancelCookieLogin()
            pollTask?.cancel()
            cooldownTask?.cancel()
        }
        // Coming back from the official app (single-device flow): if polling
        // died while we were in the background, pick it up again.
        .onChange(of: scenePhase) { _ in
            guard scenePhase == .active, mode == .qr else { return }
            if case .failed = phase { startLogin(reusingKey: true) }
            else if pollTask == nil || pollTask?.isCancelled == true { startLogin(reusingKey: true) }
        }
        .onChange(of: mode) { _ in
            cancelCookieLogin()
            pollTask?.cancel()
            if mode == .qr { startLogin(reusingKey: true) }
        }
    }

    // MARK: - QR

    private var qrSection: some View {
        VStack(spacing: 20) {
            Text("使用官方 App 扫码登录")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white)
                    .frame(width: 208, height: 208)
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)

                if let qrImage {
                    Image(platformImage: qrImage)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 180, height: 180)
                        .blur(radius: overlayVisible ? 3 : 0)
                } else {
                    ProgressView()
                }

                if overlayVisible {
                    VStack(spacing: 10) {
                        switch phase {
                        case .expired:
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(Theme.accent)
                            Text("二维码已失效")
                                .font(.system(size: 12, weight: .medium))
                            Button("刷新") {
                                startLogin()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            .controlSize(.small)
                        case .scanned(let nickname):
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.green)
                            Text("已扫码")
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(nickname)，请在手机上确认")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        default:
                            EmptyView()
                        }
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            Group {
                switch phase {
                case .loading:
                    Text("正在获取二维码…")
                case .waiting:
                    Text("打开官方 App，扫一扫登录")
                case .scanned:
                    Text("等待手机确认…")
                case .expired:
                    Text("二维码已失效，请刷新")
                case .success:
                    Text("登录成功！")
                case .failed(let message):
                    Text(message).foregroundStyle(Theme.accent)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            #if os(iOS)
            Text("只有一台设备？截图二维码，到官方 App 的扫一扫里选择相册识别，然后回到这里即可")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            #endif
        }
    }

    private var overlayVisible: Bool {
        switch phase {
        case .expired, .scanned: return true
        default: return false
        }
    }

    /// Starts (or resumes) the QR login. Polling tolerates transient network
    /// errors (the app being backgrounded while the user scans) instead of
    /// giving up on the first failure.
    private func startLogin(reusingKey: Bool = false) {
        guard isPresented, mode == .qr, !smsLoggingIn, !syncedLoggingIn, cookieAttempt == nil else { return }
        pollTask?.cancel()
        let existingKey = reusingKey ? unikey : nil
        if existingKey == nil {
            phase = .loading
            qrImage = nil
        } else {
            phase = .waiting
        }
        pollTask = Task {
            do {
                let key: String
                if let existingKey {
                    key = existingKey
                } else {
                    key = try await MusicAPI.qrKey()
                    try Task.checkCancellation()
                    unikey = key
                    guard let loginURL = MusicAPI.qrLoginURL(unikey: key) else { throw MusicAPIError.notConfigured }
                    qrImage = Self.generateQR(from: loginURL)
                    phase = .waiting
                }

                var consecutiveErrors = 0
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1.2))
                    let check: MusicAPI.QRCheckResponse
                    do {
                        check = try await MusicAPI.qrCheck(unikey: key)
                        consecutiveErrors = 0
                    } catch {
                        // Cancellation is not a transient network error.
                        // Retrying it would keep a stopped poll alive.
                        if Task.isCancelled { throw error }
                        consecutiveErrors += 1
                        if consecutiveErrors >= 15 { throw error }
                        continue
                    }
                    if Task.isCancelled {
                        // qrCheck can finish after this poll was cancelled.
                        // Code 803 has already stored Set-Cookie, so bootstrap
                        // has to run on a task that cancellation will not abort.
                        if check.code == 803 {
                            await Task { @MainActor in await account.bootstrap() }.value
                        }
                        return
                    }
                    switch check.code {
                    case 800:
                        phase = .expired
                        unikey = nil
                        return
                    case 801:
                        if case .waiting = phase {} else { phase = .waiting }
                    case 802:
                        phase = .scanned(check.nickname ?? "")
                    case 803:
                        phase = .success
                        await account.bootstrap()
                        try Task.checkCancellation()
                        ToastCenter.shared.show(String(localized: "欢迎回来，\(account.profile?.nickname ?? "")"))
                        dismiss()
                        return
                    default:
                        break
                    }
                }
            } catch {
                if !Task.isCancelled {
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - SMS

    private var smsSection: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                Text("可能被风控拦截而不可用，推荐使用扫码登录")
                    .font(.system(size: 11.5))
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 28)

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "iphone")
                        .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 20)
                    Text("+86").font(.system(size: 15, weight: .medium))
                    Rectangle().fill(.quaternary).frame(width: 1, height: 20)
                    TextField("手机号", text: $phone)
                        .textFieldStyle(.plain).font(.system(size: 15))
                        #if os(iOS)
                        .keyboardType(.phonePad).textContentType(.telephoneNumber)
                        #endif
                }
                .fieldChrome()

                HStack(spacing: 10) {
                    TextField("验证码", text: $code)
                        .textFieldStyle(.plain).font(.system(size: 15))
                        #if os(iOS)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        #endif
                    Button {
                        sendCode()
                    } label: {
                        Group {
                            if smsSending {
                                ProgressView().controlSize(.small)
                            } else if smsCooldown > 0 {
                                Text("\(smsCooldown)s").monospacedDigit()
                            } else {
                                Text("获取验证码")
                            }
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(canSendCode ? Theme.accent : .secondary)
                    }
                    .buttonStyle(.plain).disabled(!canSendCode)
                }
                .fieldChrome()
            }
            .padding(.horizontal, 28)

            if let smsMessage {
                Text(smsMessage)
                    .font(.system(size: 12)).foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }

            Button {
                loginWithCode()
            } label: {
                Group {
                    if smsLoggingIn {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Text("登录")
                    }
                }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(
                    Capsule().fill(canLogin ? AnyShapeStyle(Theme.accentGradient)
                                            : AnyShapeStyle(Color.secondary.opacity(0.25)))
                )
            }
            .buttonStyle(.pressable).disabled(!canLogin)
            .padding(.horizontal, 28).padding(.top, 2)
        }
        .frame(minHeight: 300)
    }

    private var canSendCode: Bool { !smsSending && smsCooldown == 0 && phone.count >= 11 }
    private var canLogin: Bool { !smsLoggingIn && !syncedLoggingIn && cookieAttempt == nil && phone.count >= 11 && code.count >= 4 }


    private func sendCode() {
        smsSending = true
        smsMessage = nil
        Task {
            defer { smsSending = false }
            do {
                try await MusicAPI.sendSMSCode(phone: phone)
                smsMessage = String(localized: "验证码已发送")
                smsCooldown = 60
                cooldownTask?.cancel()
                cooldownTask = Task {
                    while smsCooldown > 0, !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        smsCooldown -= 1
                    }
                }
            } catch {
                smsMessage = error.localizedDescription
            }
        }
    }

    private func loginWithCode() {
        guard canLogin else { return }
        smsLoggingIn = true
        smsMessage = nil
        Task {
            defer { smsLoggingIn = false }
            do {
                try await MusicAPI.loginCellphone(phone: phone, captcha: code)
                pollTask?.cancel()
                await account.bootstrap()
                ToastCenter.shared.show(String(localized: "欢迎回来，\(account.profile?.nickname ?? "")"))
                dismiss()
            } catch {
                smsMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Cookie

    private var cookieSection: some View {
        VStack(spacing: 16) {
            Text("在浏览器登录网易云音乐后，粘贴包含 MUSIC_U 的 Cookie；可同时包含 __csrf。请勿分享 Cookie。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)

            SecureField("Cookie 内容", text: $cookieHeader)
                .textFieldStyle(.plain)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .fieldChrome()
                .disabled(cookieAttempt != nil)
                .onSubmit { loginWithCookie() }

            if let cookieMessage {
                Text(cookieMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center)
            }

            Button(action: loginWithCookie) {
                if cookieAttempt != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Text("登录")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(cookieAttempt != nil || smsLoggingIn || syncedLoggingIn || cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 28)
        .frame(minHeight: 300)
    }

    private func cancelCookieLogin() {
        cookieAttempt = nil
        cookieTask?.cancel()
        cookieTask = nil
        cookieHeader = ""
    }

    private func loginWithCookie() {
        guard isPresented, mode == .cookie, cookieAttempt == nil, !smsLoggingIn, !syncedLoggingIn else { return }
        let attempt = UUID()
        cookieAttempt = attempt
        cookieMessage = nil
        let header = cookieHeader
        cookieTask = Task {
            defer {
                if cookieAttempt == attempt {
                    cookieAttempt = nil
                    cookieTask = nil
                }
            }
            do {
                try await account.importCookieLogin(header) {
                    isPresented && mode == .cookie && cookieAttempt == attempt
                }
                // installLogin clears the previous account's playlists and
                // liked tracks. Fetch them even if this sheet task is cancelled
                // after the credentials are committed.
                await Task { @MainActor in await account.refreshLibrary() }.value
                try Task.checkCancellation()
                guard isPresented, mode == .cookie, cookieAttempt == attempt else { return }
                cookieHeader = ""
                ToastCenter.shared.show(String(localized: "欢迎回来，\(account.profile?.nickname ?? "")"))
                dismiss()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, cookieAttempt == attempt else { return }
                cookieMessage = error.localizedDescription
            }
        }
    }

    private static func generateQR(from string: String) -> PlatformImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: 180, height: 180))
        #elseif os(iOS)
        return UIImage(cgImage: cgImage)
        #endif
    }
}

private extension View {
    func fieldChrome() -> some View {
        self
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.06), lineWidth: 1))
    }
}
